--!strict
-- FootstepController (client)
-- Toca o som de passos do PROPRIO jogador de acordo com o material do chao (Enum.Material) e REMOVE
-- o som de passos padrao do Roblox do personagem de TODOS.
--
-- Divisao com o FootstepService (server): os passos dos OUTROS jogadores vem de la, dirigidos pelos
-- KeyframeEvents "Steps" das animacoes e emitidos por um AudioEmitter no pe que pisou. Este
-- controller cuida so do passo que o dono ouve (cadencia por timer, som no HumanoidRootPart) — por
-- isso PLAY_FOR_LOCAL_PLAYER_ONLY: sem esse gate, cada passo alheio tocaria duas vezes.
-- Pelo mesmo motivo, o AudioEmitter dinamico do PROPRIO personagem e silenciado localmente
-- (:_muteOwnDynamicFootsteps) — mudanca local, que nao replica: os outros continuam ouvindo.
--
-- O rastreio continua sendo de TODOS os personagens porque a silenciacao do passo padrao do Roblox
-- (som "Running") precisa acontecer para cada um deles.
--
-- O som padrao de passos e o "Running" que o RbxCharacterSounds cria dentro do HumanoidRootPart.
-- Em vez de destrui-lo (o RbxCharacterSounds mantem referencia e voltaria a setar propriedades num
-- objeto destruido, gerando erros), zeramos o Volume dele - o loop do RbxCharacterSounds nunca
-- reescreve Volume, entao o passo padrao fica permanentemente mudo.
--
-- Os ids por material ficam em ReplicatedStorage.Shared.SharedModules.FootstepSounds (placeholders
-- 0 ate serem substituidos pelos sons reais).
--
-- No Start, TODOS os sons do catalogo sao pre-carregados (ContentProvider:PreloadAsync) e ficam em
-- cache como "templates" mudos. Com a duracao real (TimeLength) em maos, cada som recebe um
-- PlaybackSpeed base que normaliza a duracao para FootstepSounds.Config.NormalizedDuration - assim
-- todos os materiais tocam pelo mesmo tempo (cadencia uniforme, ja que o passo seguinte so e
-- processado quando o som atual termina). Ao tocar, o template e clonado (sem recarregar o asset).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContentProvider = game:GetService("ContentProvider")
local Debris = game:GetService("Debris")

local FootstepSounds = require(ReplicatedStorage.Shared.SharedModules.FootstepSounds)

-- Nome do som de passos padrao criado pelo RbxCharacterSounds (em HumanoidRootPart).
local DEFAULT_FOOTSTEP_SOUND_NAME = "Running"

-- Toca o passo por timer apenas para o personagem do jogador local (os demais sao servidos pelo
-- FootstepService). Deixe false para voltar ao comportamento antigo (todos por timer) — mas ai
-- desligue tambem o FootstepService, senao os passos alheios dobram.
local PLAY_FOR_LOCAL_PLAYER_ONLY = true

-- Grupo de interacao usado para silenciar LOCALMENTE o AudioEmitter dinamico do proprio personagem:
-- nenhum AudioListener escuta este grupo (o do AudioListenerController e "General"), e a alteracao
-- feita aqui nao replica, entao os outros jogadores seguem ouvindo o passo normalmente.
local MUTED_INTERACTION_GROUP = "LocalFootstepMuted"

local LocalPlayer = Players.LocalPlayer

-- Estado por personagem rastreado.
type Tracked = {
	humanoid: Humanoid,
	rootPart: BasePart,
	-- Se e o personagem do jogador local (define quem toca o passo por timer).
	isLocal: boolean,
	-- Tempo (s) acumulado desde o ultimo passo; comparado ao intervalo (por velocidade). Resetado
	-- quando o personagem para.
	timeSinceStep: number,
	-- Som do passo atualmente tocando (nil quando nenhum toca). Enquanto estiver setado, nenhum
	-- novo passo e tocado; e limpo quando o som termina (Ended/destruido), liberando o proximo.
	currentSound: Sound?,
	-- Asset id do ultimo passo sorteado, para nao repetir o mesmo som duas vezes seguidas.
	lastAssetId: number?,
}

-- Som em cache: o template (mudo, so para clonar) e o PlaybackSpeed que normaliza a duracao.
type CachedSound = {
	template: Sound,
	basePlaybackSpeed: number,
}

local FootstepController = {}
-- Personagem -> estado. Um unico loop de Heartbeat percorre todos.
FootstepController._tracked = {} :: { [Model]: Tracked }
-- assetId -> som em cache (pre-carregado e normalizado). Populado por _loadSounds no Start.
FootstepController._soundCache = {} :: { [number]: CachedSound }
-- Folder que segura os templates (mantem-os no DataModel; nunca tocam diretamente).
FootstepController._cacheFolder = nil :: Folder?

-- Zera o volume do som de passos padrao (atual e qualquer um adicionado depois, ja que o
-- RbxCharacterSounds roda de forma assincrona).
function FootstepController:_silenceDefaultFootsteps(rootPart: BasePart)
	local function silence(child: Instance)
		if child.Name == DEFAULT_FOOTSTEP_SOUND_NAME and child:IsA("Sound") then
			child.Volume = 0
		end
	end

	for _, child in rootPart:GetChildren() do
		silence(child)
	end
	rootPart.ChildAdded:Connect(silence)
end

-- Tira o AudioEmitter dinamico (criado pelo FootstepService no pe do personagem) do grupo de
-- interacao do listener, SO NESTE CLIENT: o dono deixa de ouvir o proprio passo dinamico e continua
-- ouvindo apenas o passo por timer deste controller. Como o emitter e reparentado entre os pes a
-- cada passo, tambem acompanhamos DescendantAdded (a operacao e idempotente).
function FootstepController:_muteOwnDynamicFootsteps(character: Model)
	local emitterName = FootstepSounds.EmitterConfig.EmitterName

	local function mute(instance: Instance)
		if instance.Name == emitterName and instance:IsA("AudioEmitter") then
			instance.AudioInteractionGroup = MUTED_INTERACTION_GROUP
		end
	end

	for _, descendant in character:GetDescendants() do
		mute(descendant)
	end
	character.DescendantAdded:Connect(mute)
end

-- Raycast curto para baixo a partir do personagem para inspecionar a peca do chao. Retorna:
--   custom  -> valor do atributo "CustomFootstep" da peca (string), se houver (tem prioridade);
--   variant -> MaterialVariant da peca (Humanoid.FloorMaterial so da o Enum.Material base), se houver.
-- Ambos podem ser nil.
-- (implementacao compartilhada com o FootstepService, no modulo FootstepSounds)
function FootstepController:_getFloorInfo(character: Model, rootPart: BasePart): (string?, string?)
	return FootstepSounds.GetFloorInfo(character, rootPart)
end

-- Pre-carrega TODOS os sons do catalogo, deixa-os em cache como templates e calcula o PlaybackSpeed
-- base que normaliza a duracao de cada um para Config.NormalizedDuration. Yielda no PreloadAsync;
-- chamado uma vez (em task.spawn) no Start.
function FootstepController:_loadSounds()
	local cfg = FootstepSounds.Config
	local folder = Instance.new("Folder")
	folder.Name = "FootstepSoundCache"
	folder.Parent = script
	self._cacheFolder = folder

	-- Cria um template mudo por asset id e registra no cache (basePlaybackSpeed ajustado apos load).
	-- Junto criamos um AudioPlayer por id (AutoLoad ligado, nunca tocado): ele nao entra no cache,
	-- serve so para o engine ja ter o asset carregado na API de audio nova quando o FootstepService
	-- mandar o AudioEmitter do personagem tocar — senao o PRIMEIRO passo de cada som sairia atrasado.
	local templates: { Sound } = {}
	for _, assetId in FootstepSounds.GetAllIds() do
		local sound = Instance.new("Sound")
		sound.SoundId = "rbxassetid://" .. assetId
		sound.Parent = folder
		self._soundCache[assetId] = { template = sound, basePlaybackSpeed = 1 }
		table.insert(templates, sound)

		local warmup = Instance.new("AudioPlayer")
		warmup.AssetId = "rbxassetid://" .. assetId
		warmup.Volume = 0
		warmup.Parent = folder
	end

	if #templates > 0 then
		ContentProvider:PreloadAsync(templates)
	end

	-- Com os sons carregados, TimeLength e valido: normaliza para a mesma duracao alvo.
	for _, cached in self._soundCache do
		local length = cached.template.TimeLength
		if length > 0 then
			cached.basePlaybackSpeed = length / cfg.NormalizedDuration
		end
	end
end

-- Cria e toca um som de passo unico para o material/variant atual do chao do personagem. Clona o
-- template em cache (ja carregado e com a duracao normalizada). Marca state.currentSound enquanto
-- toca: o _update nao toca novos passos ate terminar.
function FootstepController:_playStep(state: Tracked, character: Model, humanoid: Humanoid, rootPart: BasePart)
	local material = humanoid.FloorMaterial
	if material == Enum.Material.Air then
		return
	end
	if state.currentSound then
		return
	end
	-- Superficie customizada (atributo CustomFootstep) tem prioridade sobre o material/variant.
	-- Passa o ultimo som tocado para nao sortear ele de novo (a menos que seja a unica variacao).
	local custom, variant = self:_getFloorInfo(character, rootPart)
	local assetId
	if custom then
		assetId = FootstepSounds.GetRandomCustomId(custom, state.lastAssetId)
	else
		assetId = FootstepSounds.GetRandomId(material, variant, state.lastAssetId)
	end
	if not assetId then
		return -- so com placeholders (ou custom inexistente): nao toca nada
	end

	local cached = self._soundCache[assetId]
	if not cached then
		return -- ainda nao carregado/cacheado: nao toca neste frame
	end

	-- Registra como ultimo som para a proxima escolha evita-lo.
	state.lastAssetId = assetId

	local cfg = FootstepSounds.Config
	local sound = cached.template:Clone()
	sound.Volume = cfg.Volume
	-- PlaybackSpeed que normaliza a duracao do som para NormalizedDuration (igual para qualquer
	-- velocidade); o tom nao muda com a velocidade do personagem.
	sound.PlaybackSpeed = cached.basePlaybackSpeed
	sound.RollOffMaxDistance = cfg.RollOffMaxDistance
	sound.Parent = rootPart
	sound:Play()
	state.currentSound = sound

	-- Limpa a referencia quando o som e destruido (por Ended ou pela rede de seguranca do Debris),
	-- liberando o _update para computar o proximo passo.
	sound.Destroying:Once(function()
		if state.currentSound == sound then
			state.currentSound = nil
		end
	end)
	sound.Ended:Once(function()
		sound:Destroy()
	end)
	-- Rede de seguranca caso o som seja invalido e Ended nao dispare.
	Debris:AddItem(sound, 5)
end

-- Comeca a rastrear um personagem (qualquer jogador): muta o passo padrao e registra o estado.
function FootstepController:_trackCharacter(character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	local rootPart = character:WaitForChild("HumanoidRootPart", 10) :: BasePart?
	if not humanoid or not rootPart or not character.Parent then
		return
	end

	self:_silenceDefaultFootsteps(rootPart)

	local isLocal = Players:GetPlayerFromCharacter(character) == LocalPlayer
	if isLocal then
		-- O dono nao ouve o proprio passo dinamico (server); ouve so o passo por timer daqui.
		self:_muteOwnDynamicFootsteps(character)
	end

	self._tracked[character] = {
		humanoid = humanoid,
		rootPart = rootPart,
		isLocal = isLocal,
		timeSinceStep = 0,
	}

	character.Destroying:Once(function()
		self._tracked[character] = nil
	end)
end

-- Acompanha todos os personagens (atual + futuros) de um jogador.
function FootstepController:_trackPlayer(player: Player)
	if player.Character then
		task.spawn(function()
			self:_trackCharacter(player.Character :: Model)
		end)
	end
	player.CharacterAdded:Connect(function(character)
		self:_trackCharacter(character)
	end)
end

-- Avalia um personagem rastreado (chamado a cada frame com o dt do Heartbeat). Acumula o tempo e
-- toca um passo quando passa o intervalo (calculado pela velocidade da rootpart), respeitando o gate
-- de "um som por vez": a cadencia efetiva e o maior entre o intervalo e a duracao do som.
function FootstepController:_update(character: Model, state: Tracked, dt: number)
	local rootPart = state.rootPart
	local humanoid = state.humanoid

	if not character.Parent or humanoid.Health <= 0 then
		state.timeSinceStep = 0
		return
	end

	-- Os passos dos outros jogadores vem do FootstepService (por keyframe, no pe); aqui so o proprio.
	if PLAY_FOR_LOCAL_PLAYER_ONLY and not state.isLocal then
		state.timeSinceStep = 0
		return
	end

	-- O player local agachado nao faz barulho de passos (o agachar e estado local, vindo do
	-- HumanoidController). So vale para o proprio personagem; os demais nao tem esse estado aqui.
	if state.isLocal then
		local HumanoidController = self.GetController and self.GetController("HumanoidController")
		if HumanoidController and HumanoidController:IsCrouchingState() then
			state.timeSinceStep = 0
			return
		end
	end

	-- Precisa estar no chao (estado Running cobre andar e correr) e de fato se movendo.
	local humanoidState = humanoid:GetState()
	local onGround = humanoidState == Enum.HumanoidStateType.Running
		or humanoidState == Enum.HumanoidStateType.RunningNoPhysics
	if not onGround or humanoid.MoveDirection.Magnitude < 0.1 then
		state.timeSinceStep = 0
		return
	end

	-- Velocidade horizontal real da rootpart (ignora subida/queda); define o intervalo entre passos.
	local velocity = rootPart.AssemblyLinearVelocity
	local speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	if speed < 0.1 then
		state.timeSinceStep = 0
		return
	end

	state.timeSinceStep += dt

	-- Um passo por vez: enquanto o som do passo atual estiver tocando, nao toca outro (mas o tempo
	-- segue acumulando acima, entao o proximo dispara assim que o som terminar se o intervalo ja passou).
	if state.currentSound then
		return
	end

	-- Intervalo entre passos proporcional a velocidade: mais rapido => intervalo menor.
	local cfg = FootstepSounds.Config
	local interval = math.clamp(
		cfg.BaseStepInterval * cfg.BaseStepSpeed / speed,
		cfg.MinStepInterval,
		cfg.MaxStepInterval
	)
	if state.timeSinceStep >= interval then
		state.timeSinceStep = 0
		self:_playStep(state, character, humanoid, rootPart)
	end
end

function FootstepController:Start()
	-- Pre-carrega/normaliza todos os sons em paralelo (yielda no PreloadAsync); ate terminar, o
	-- _playStep simplesmente nao toca (cache vazio). Nao bloqueia a init dos demais controllers.
	task.spawn(function()
		self:_loadSounds()
	end)

	for _, player in Players:GetPlayers() do
		self:_trackPlayer(player)
	end
	Players.PlayerAdded:Connect(function(player)
		self:_trackPlayer(player)
	end)

	-- Loop unico para todos os personagens rastreados.
	RunService.Heartbeat:Connect(function(dt)
		for character, state in self._tracked do
			self:_update(character, state, dt)
		end
	end)

	print("✓ FootstepController initialized")
end

return FootstepController
