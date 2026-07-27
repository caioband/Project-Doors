--!strict
-- FootstepService (server)
-- Passos DINAMICOS dirigidos pelas animacoes: as animacoes de andar/correr do player carregam
-- KeyframeEvents chamados "Steps" cujo parametro e "Right" ou "Left" (qual pe pisou). A cada marker
-- alcancado, o server toca um passo POSICIONADO NO PE correspondente.
--
-- Como as animacoes sao tocadas no client dono do personagem (HumanoidController), elas replicam
-- para o server; aqui escutamos Animator.AnimationPlayed e, de cada track, o
-- GetMarkerReachedSignal("Steps"). Assim a cadencia vem da propria animacao (nao de um timer).
--
-- Cadeia de audio criada por personagem (uma unica vez, no primeiro passo):
--   Pe (RightFoot/LeftFoot)
--     +-- FootstepEmitter (AudioEmitter, grupo "General")
--           +-- FootstepPlayer (AudioPlayer)  --Wire--> FootstepEmitter.Input
-- A cada passo o emitter e REPARENTADO para o pe que pisou (nao criamos um novo par por passo) e o
-- AudioPlayer recebe o AssetId sorteado e toca uma vez.
--
-- Os asset ids sao os MESMOS do sistema por timer: ReplicatedStorage.Shared.SharedModules
-- .FootstepSounds (por Enum.Material + MaterialVariant, com prioridade para o atributo
-- "CustomFootstep" da peca do chao). Parametros do emitter em FootstepSounds.EmitterConfig.
--
-- Cada passo tambem vira um EVENTO DE RUIDO no NoiseService (posicao do pe + raio pela velocidade),
-- que e como o BusinessMan caca: ele e cego e persegue barulho. O ruido e reportado mesmo quando o
-- material nao tem asset id — barulho e gameplay, som e apresentacao.
--
-- O DONO do personagem nao ouve o proprio passo dinamico: o FootstepController (client) tira o
-- AudioEmitter do proprio character do grupo de interacao do listener (mudanca puramente local, nao
-- replica), entao os OUTROS jogadores continuam ouvindo normalmente. O passo que o dono ouve
-- continua vindo do FootstepController.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FootstepSounds = require(ReplicatedStorage.Shared.SharedModules.FootstepSounds)

-- Nomes aceitos para o KeyframeEvent das animacoes de andar/correr (parametro: "Right" | "Left").
-- Os assets usam "Step" (singular); "Steps" fica aceito para nao quebrar se alguem renomear.
-- Conectar os dois e barato e nao duplica passo: o gate MinSideInterval ja suprime repeticao do
-- mesmo lado. IMPORTANTE: GetMarkerReachedSignal NAO reclama de um nome inexistente — ele devolve um
-- sinal que nunca dispara. Um nome errado aqui e uma falha 100% silenciosa.
local MARKER_NAMES = { "Step", "Steps" }

-- Partes candidatas a "pe" por lado, em ordem de preferencia (R15 -> R6). Se nenhuma existir,
-- caimos no HumanoidRootPart (o passo ainda toca, so nao fica no pe).
local FOOT_PARTS: { [string]: { string } } = {
	Left = { "LeftFoot", "LeftLowerLeg", "LeftUpperLeg", "Left Leg" },
	Right = { "RightFoot", "RightLowerLeg", "RightUpperLeg", "Right Leg" },
}

-- Estado por personagem rastreado.
type Tracked = {
	character: Model,
	humanoid: Humanoid,
	rootPart: BasePart,
	-- Par de audio criado sob demanda no primeiro passo e reutilizado (o emitter e reparentado).
	emitter: AudioEmitter?,
	audioPlayer: AudioPlayer?,
	-- Ultimo asset id tocado, para nao sortear o mesmo som duas vezes seguidas.
	lastAssetId: number?,
	-- Ultimo instante (os.clock) em que cada lado tocou; usado pelo anti-duplicata.
	lastStepAt: { [string]: number },
	-- AnimationId (ou a propria track, se ela nao tiver id) -> conexao do marker. Uma por animacao:
	-- se a mesma animacao voltar a tocar (o HumanoidController alterna Walk/Run o tempo todo), a
	-- conexao antiga e substituida em vez de acumular (senao o mesmo passo tocaria N vezes).
	markerConns: { [any]: RBXScriptConnection },
	connections: { RBXScriptConnection },
}

local FootstepService = {}
FootstepService._tracked = {} :: { [Model]: Tracked }
-- NoiseService resolvido preguicosamente (false = ja procurado e ausente). Ver :_getNoiseService.
FootstepService._noiseService = nil :: any

-- Normaliza o parametro do KeyframeEvent para "Left" ou "Right". Aceita variacoes de caixa e
-- abreviacoes ("L"/"R"); qualquer outra coisa cai em "Right" (melhor tocar do lado errado do que
-- nao tocar).
local function normalizeSide(param: any): string
	if typeof(param) ~= "string" then
		return "Right"
	end
	local trimmed = (string.gsub(param, "%s", ""))
	local value = string.lower(trimmed)
	if value == "left" or value == "l" then
		return "Left"
	end
	return "Right"
end

-- Acha a BasePart do pe do lado pedido (R15 ou R6); HumanoidRootPart como ultimo recurso.
local function findFootPart(character: Model, side: string, rootPart: BasePart): BasePart
	for _, name in FOOT_PARTS[side] do
		local part = character:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			return part
		end
	end
	return rootPart
end

-- Aplica a atenuacao por distancia no emitter. A API do AudioEmitter mudou de propriedades
-- RollOff* para SetDistanceAttenuation (curva distancia -> ganho); tentamos a curva primeiro e
-- caimos nas propriedades antigas se o metodo nao existir nesta versao do engine.
local function applyAttenuation(emitter: AudioEmitter, minDistance: number, maxDistance: number)
	local target = emitter :: any

	local ok = pcall(function()
		target:SetDistanceAttenuation({
			[0] = 1,
			[minDistance] = 1,
			[maxDistance] = 0,
		})
	end)
	if ok then
		return
	end

	pcall(function()
		target.RollOffMinDistance = minDistance
		target.RollOffMaxDistance = maxDistance
	end)
end

-- Cria (uma unica vez por personagem) o AudioEmitter + AudioPlayer + Wire, ja parented no pe dado.
-- Retorna nil se o personagem saiu do jogo no meio.
function FootstepService:_ensureAudio(state: Tracked, foot: BasePart): (AudioEmitter?, AudioPlayer?)
	if state.emitter and state.emitter.Parent and state.audioPlayer then
		return state.emitter, state.audioPlayer
	end
	if not state.character.Parent then
		return nil, nil
	end

	local cfg = FootstepSounds.EmitterConfig

	local emitter = Instance.new("AudioEmitter")
	emitter.Name = cfg.EmitterName
	emitter.AudioInteractionGroup = cfg.AudioInteractionGroup
	applyAttenuation(emitter, cfg.RollOffMinDistance, cfg.RollOffMaxDistance)

	local audioPlayer = Instance.new("AudioPlayer")
	audioPlayer.Name = cfg.PlayerName
	audioPlayer.Volume = cfg.Volume
	audioPlayer.PlaybackSpeed = cfg.PlaybackSpeed
	audioPlayer.Looping = false
	audioPlayer.Parent = emitter

	-- Liga a saida do player na entrada do emitter (o que torna o som espacial na posicao do pe).
	local wire = Instance.new("Wire")
	wire.SourceInstance = audioPlayer
	wire.SourceName = "Output"
	wire.TargetInstance = emitter
	wire.TargetName = "Input"
	wire.Parent = audioPlayer

	emitter.Parent = foot

	state.emitter = emitter
	state.audioPlayer = audioPlayer
	return emitter, audioPlayer
end

-- Resolve (e cacheia) o NoiseService. O GetService e injetado pelo Services/init.server.lua antes
-- de qualquer Init/Start, entao a busca preguicosa aqui nao depende da ordem de boot dos Services.
function FootstepService:_getNoiseService(): any
	if self._noiseService == nil then
		self._noiseService = (self.GetService and self.GetService("NoiseService")) or false
	end
	return self._noiseService or nil
end

-- Alimenta o NoiseService com o barulho deste passo. O raio vem da VELOCIDADE horizontal da
-- rootpart no instante do passo (ver FootstepSounds.NoiseConfig): correr faz muito mais barulho que
-- andar, e o agachado — que anda a WalkSpeed 3 — fica quase mudo sem precisar de caso especial.
function FootstepService:_reportNoise(state: Tracked, position: Vector3)
	local noiseService = self:_getNoiseService()
	if not noiseService then
		return
	end

	local cfg = FootstepSounds.NoiseConfig
	local velocity = state.rootPart.AssemblyLinearVelocity
	local speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	local radius = math.clamp(cfg.BaseRadius * speed / cfg.BaseSpeed, cfg.MinRadius, cfg.MaxRadius)

	noiseService:Report(position, radius, "Footstep", Players:GetPlayerFromCharacter(state.character))
end

-- Um passo: sorteia o som pelo chao atual, redireciona o emitter para o pe que pisou e toca 1x.
function FootstepService:_playStep(state: Tracked, side: string)
	local character = state.character
	local humanoid = state.humanoid
	local rootPart = state.rootPart

	if not character.Parent or humanoid.Health <= 0 then
		return
	end

	-- No ar (pulo/queda) nao ha superficie para sonorizar.
	local material = humanoid.FloorMaterial
	if material == Enum.Material.Air then
		return
	end

	-- Anti-duplicata: o mesmo lado nao toca duas vezes em sequencia imediata.
	local cfg = FootstepSounds.EmitterConfig
	local now = os.clock()
	local last = state.lastStepAt[side]
	if last and now - last < cfg.MinSideInterval then
		return
	end
	state.lastStepAt[side] = now

	-- O pe que pisou: destino do emitter e origem do ruido.
	local foot = findFootPart(character, side, rootPart)

	-- RUIDO antes do som: o passo alimenta o NoiseService mesmo que o material nao tenha asset id
	-- (o barulho e gameplay — o BusinessMan caca por ele; o som e apresentacao).
	self:_reportNoise(state, foot.Position)

	-- Superficie customizada (atributo "CustomFootstep" da peca) tem prioridade sobre material/variant.
	-- Passa o ultimo id tocado para nao repetir o mesmo som em passos seguidos.
	local custom, variant = FootstepSounds.GetFloorInfo(character, rootPart)
	local assetId: number?
	if custom then
		assetId = FootstepSounds.GetRandomCustomId(custom, state.lastAssetId)
	else
		assetId = FootstepSounds.GetRandomId(material, variant, state.lastAssetId)
	end
	if not assetId then
		return -- so placeholders (id 0) ou chave custom inexistente: nao toca nada
	end
	state.lastAssetId = assetId

	local emitter, audioPlayer = self:_ensureAudio(state, foot)
	if not emitter or not audioPlayer then
		return
	end

	-- Redireciona o emitter para o pe que acabou de pisar (o mesmo par serve os dois pes).
	if emitter.Parent ~= foot then
		emitter.Parent = foot
	end

	audioPlayer.AssetId = "rbxassetid://" .. assetId
	audioPlayer.TimePosition = 0
	audioPlayer:Play()
end

-- Conecta os markers de passo de uma AnimationTrack. Deduplica por AnimationId + nome do marker: o
-- HumanoidController para/toca as tracks de movimento constantemente e o AnimationPlayed dispara em
-- cada retomada — sem a dedup, cada retomada somaria mais uma conexao e o passo tocaria N vezes.
function FootstepService:_bindTrack(state: Tracked, track: AnimationTrack)
	-- Chave de deduplicacao: o AnimationId (estavel entre replays) ou, na falta dele, a track.
	local animation = track.Animation
	local baseKey: any = track
	if animation and animation.AnimationId ~= "" then
		baseKey = animation.AnimationId
	end

	for _, markerName in MARKER_NAMES do
		local ok, signal = pcall(function()
			return track:GetMarkerReachedSignal(markerName)
		end)
		if ok and signal then
			local key = tostring(baseKey) .. "|" .. markerName
			local existing = state.markerConns[key]
			if existing then
				existing:Disconnect()
			end
			state.markerConns[key] = signal:Connect(function(param: any)
				self:_playStep(state, normalizeSide(param))
			end)
		end
	end
end

-- Comeca a rastrear um personagem: escuta as animacoes que ele tocar (inclusive as ja em execucao).
function FootstepService:TrackCharacter(character: Model)
	if self._tracked[character] then
		return
	end

	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	local rootPart = character:WaitForChild("HumanoidRootPart", 10) :: BasePart?
	if not humanoid or not rootPart or not character.Parent then
		return
	end

	local animator = humanoid:WaitForChild("Animator", 10) :: Animator?
	if not animator or not character.Parent then
		return
	end

	local state: Tracked = {
		character = character,
		humanoid = humanoid,
		rootPart = rootPart,
		emitter = nil,
		audioPlayer = nil,
		lastAssetId = nil,
		lastStepAt = {},
		markerConns = {},
		connections = {},
	}
	self._tracked[character] = state

	-- Tracks que ja estavam tocando quando comecamos a rastrear (ex.: reentrada do service).
	for _, track in animator:GetPlayingAnimationTracks() do
		self:_bindTrack(state, track)
	end

	table.insert(
		state.connections,
		animator.AnimationPlayed:Connect(function(track)
			self:_bindTrack(state, track)
		end)
	)

	character.Destroying:Once(function()
		self:UntrackCharacter(character)
	end)
end

-- Solta todas as conexoes do personagem (o emitter/player morrem junto com o character).
function FootstepService:UntrackCharacter(character: Model)
	local state = self._tracked[character]
	if not state then
		return
	end
	self._tracked[character] = nil

	for _, conn in state.markerConns do
		conn:Disconnect()
	end
	for _, conn in state.connections do
		conn:Disconnect()
	end
	state.markerConns = {}
	state.connections = {}
end

-- Acompanha todos os personagens (atual + futuros) de um jogador.
function FootstepService:_trackPlayer(player: Player)
	if player.Character then
		task.spawn(function()
			self:TrackCharacter(player.Character :: Model)
		end)
	end
	player.CharacterAdded:Connect(function(character)
		task.spawn(function()
			self:TrackCharacter(character)
		end)
	end)
	-- Rede de seguranca: nem todo respawn destroi o character (o Destroying pode nao disparar).
	player.CharacterRemoving:Connect(function(character)
		self:UntrackCharacter(character)
	end)
end

function FootstepService:Start()
	for _, player in Players:GetPlayers() do
		self:_trackPlayer(player)
	end
	Players.PlayerAdded:Connect(function(player)
		self:_trackPlayer(player)
	end)

	print("✓ FootstepService initialized")
end

return FootstepService
