--!strict
-- NoiseService (server)
-- Hub de RUIDO do jogo: quem faz barulho reporta um evento {posicao, raio, tempo} aqui, e quem
-- "ouve" (hoje o BusinessMan, via NPCAgent:Hear) consulta. Auto-descoberto por
-- Services/init.server.lua (:Init/:Start, com GetService injetado).
--
-- Por que uma percepcao LOGICA em vez de AudioListener/AudioAnalyzer de verdade: todo o
-- processamento de audio e DESLIGADO no server (AudioAnalyzer.RmsLevel/PeakLevel sao "Not
-- Replicated" e retornam sempre 0 em script de server), e os NPCs sao server-autoritativos
-- (SetNetworkOwner(nil)). Fazer a deteccao no client dessincronizaria o comportamento entre
-- jogadores (o NPC perseguiria na tela de um e nao na do outro) e deixaria "o monstro me ouviu" na
-- mao do client. Aqui o raio de cada ruido e um numero controlavel, igual para todo mundo.
--
-- A UNICA excecao e a VOZ: o nivel do microfone so existe no client dono, entao ele reporta pelo
-- remote Comms.Noise.ReportVoice — e o server IGNORA qualquer posicao vinda do client (usa o
-- HumanoidRootPart do proprio personagem) e limita a taxa por player.
--
-- Fontes ligadas hoje:
--   * FootstepService  - um evento por passo, raio pela velocidade (correr >> andar > agachado)
--   * DoorService      - porta aberta por um player pelo ProximityPrompt
--   * :BindMapAudio    - qualquer AudioPlayer do mapa com o atributo "NoiseRadius" (telefones do
--                        Office, servidores...), enquanto estiver tocando
--   * Voz              - ver acima

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

export type NoiseEvent = {
	-- Onde o barulho aconteceu.
	Position: Vector3,
	-- Ate quantos studs ele e audivel (o "volume" do ruido, em distancia).
	Radius: number,
	-- os.clock() do momento em que foi reportado.
	Time: number,
	-- "Footstep" | "Door" | "Audio" | "Voice" | livre (so para debug/telemetria).
	Source: string,
	-- Quem causou (nil para ruido do proprio mapa, ex.: telefone tocando).
	Player: Player?,
}

local CONFIG = {
	-- Tempo (s) que um evento fica na lista antes de ser podado. Curto de proposito: ruido e um
	-- EVENTO instantaneo, nao um estado — quem quer memoria mais longa e o estado do NPC.
	EventTTL = 2,
	-- Intervalo (s) com que um AudioPlayer ligado (:BindAudioPlayer) re-reporta enquanto toca.
	AudioRepeatInterval = 0.4,
	-- Oclusao: multiplicador do raio quando ha geometria entre o ouvinte e o ruido. Parede ABAFA,
	-- nao bloqueia (1 = desliga a checagem e economiza os raycasts).
	WallDampening = 0.5,

	-- Voz (microfone). Raio = nivel (0..1) * VoiceRadiusScale, limitado por VoiceMaxRadius.
	VoiceEnabled = true,
	VoiceRadiusScale = 90,
	VoiceMaxRadius = 60,
	-- Intervalo minimo (s) entre reports de voz ACEITOS por player (anti-flood do remote).
	VoiceMinInterval = 0.2,

	-- Raio do ruido de uma porta sendo aberta por um player.
	DoorRadius = 35,
}

local NoiseService = {}
NoiseService.Config = CONFIG

-- Eventos vivos (podados por EventTTL no Heartbeat).
local events: { NoiseEvent } = {}

-- AudioPlayers ligados: [AudioPlayer] -> { Radius, Map, NextAt }.
type BoundAudio = { Radius: number, Map: Model?, NextAt: number }
local boundAudio: { [AudioPlayer]: BoundAudio } = {}

-- Ultimo report de voz aceito por player (rate-limit).
local lastVoiceAt: { [Player]: number } = {}

local ReportVoiceRemote: RemoteEvent


-- Garante a hierarquia ReplicatedStorage.Comms.Noise e o remote de voz (mesmo padrao dos demais
-- Services).
local function EnsureRemotes()
	local comms = ReplicatedStorage:FindFirstChild("Comms")
	if not comms then
		comms = Instance.new("Folder")
		comms.Name = "Comms"
		comms.Parent = ReplicatedStorage
	end

	local folder = comms:FindFirstChild("Noise")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Noise"
		folder.Parent = comms
	end

	ReportVoiceRemote = folder:FindFirstChild("ReportVoice") :: RemoteEvent
	if not ReportVoiceRemote then
		ReportVoiceRemote = Instance.new("RemoteEvent")
		ReportVoiceRemote.Name = "ReportVoice"
		ReportVoiceRemote.Parent = folder
	end
end


--== Reportar =================================================================================

-- Registra um barulho. `radius` e ate onde ele e audivel (studs); <= 0 e ignorado (permite
-- silenciar uma fonte so zerando a config dela).
function NoiseService:Report(position: Vector3, radius: number, source: string, player: Player?)
	if radius <= 0 then
		return
	end
	table.insert(events, {
		Position = position,
		Radius = radius,
		Time = os.clock(),
		Source = source,
		Player = player,
	})
end


--== Consultar ================================================================================

-- Ha geometria entre 'from' e 'to'? Ignora personagens/NPCs (passamos o Model do consultante em
-- `ignore`); o que importa e parede/porta fechada, nao corpos no caminho.
local function isOccluded(from: Vector3, to: Vector3, ignore: Instance?): boolean
	local direction = to - from
	if direction.Magnitude < 0.1 then
		return false
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	local filter: { Instance } = {}
	if ignore then
		table.insert(filter, ignore)
	end
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(filter, p.Character)
		end
	end
	params.FilterDescendantsInstances = filter
	-- So geometria SOLIDA abafa. Sem isto, as parts marcadoras nao-colidiveis do mapa (ex.: os
	-- PathfindingObstacles do Office, que sao CanCollide=false mas CanQuery=true) contariam como
	-- parede e cortariam o alcance do ruido pela metade sem motivo.
	pcall(function()
		(params :: any).RespectCanCollide = true
	end)

	return Workspace:Raycast(from, direction, params) ~= nil
end

-- O barulho mais RELEVANTE audivel de `position`, entre os reportados depois de `sinceTime`.
--   * `multiplier` escala o alcance do ouvinte (NPC com audicao melhor/pior; ver HearingMultiplier)
--   * relevancia = raioEfetivo / distancia — favorece o barulho mais "alto" em relacao a distancia,
--     nao simplesmente o mais proximo (um grito longe ganha de um passo colado)
--   * desempate pelo mais recente
-- Retorna nil se nada for audivel.
function NoiseService:Query(position: Vector3, multiplier: number, sinceTime: number, ignore: Instance?): NoiseEvent?
	local best: NoiseEvent? = nil
	local bestScore = -1

	for _, event in events do
		if event.Time > sinceTime then
			local dist = (event.Position - position).Magnitude
			local reach = event.Radius * multiplier
			-- Descarta pelo alcance CHEIO antes de gastar raycast; a oclusao so pode diminuir.
			if dist <= reach then
				if CONFIG.WallDampening < 1 and isOccluded(position, event.Position, ignore) then
					reach *= CONFIG.WallDampening
				end
				if dist <= reach then
					local score = reach / math.max(dist, 1)
					if score > bestScore or (score == bestScore and best and event.Time > best.Time) then
						best = event
						bestScore = score
					end
				end
			end
		end
	end

	return best
end


--== Audio do mapa ============================================================================

-- Posicao de uma BasePart que "segura" um AudioEmitter (o emitter soa da posicao do pai dele).
local function emitterPosition(emitter: Instance): Vector3?
	local parent = emitter.Parent
	if parent and parent:IsA("BasePart") then
		return parent.Position
	end
	return nil
end

-- Posicao de onde um AudioPlayer "soa", em ordem de preferencia:
--   1) o AudioEmitter ligado a ele por Wire (a posicao real do som para os jogadores);
--   2) a BasePart ancestral (AudioPlayer autorado direto numa peca);
--   3) qualquer AudioEmitter dentro do Model ancestral.
--
-- O passo 3 existe porque nem todo AudioPlayer autorado esta wired: no Office, 9 dos 11 Servers tem
-- ServerStartBoot/ServerTurnOff SEM Wire (ficam em ServerN.Audios, um Folder — sem BasePart
-- ancestral). Sem esse fallback eles nao teriam posicao e o NoiseRadius neles nao faria nada.
-- Vale como aproximacao porque cada Server tem um unico emitter (CubeMonitor.AudioEmitter), que e
-- para onde aqueles audios deveriam apontar.
local function resolveAudioPosition(audioPlayer: AudioPlayer): Vector3?
	local ok, wires = pcall(function()
		return audioPlayer:GetConnectedWires("Output")
	end)
	if ok and wires then
		for _, wire in wires do
			local target = (wire :: Wire).TargetInstance
			if target and target:IsA("AudioEmitter") then
				local position = emitterPosition(target)
				if position then
					return position
				end
			end
		end
	end

	local part = audioPlayer:FindFirstAncestorWhichIsA("BasePart")
	if part then
		return part.Position
	end

	local model = audioPlayer:FindFirstAncestorOfClass("Model")
	if model then
		for _, descendant in model:GetDescendants() do
			if descendant:IsA("AudioEmitter") then
				local position = emitterPosition(descendant)
				if position then
					return position
				end
			end
		end
	end

	return nil
end

-- Faz um AudioPlayer virar fonte de ruido: enquanto ele estiver TOCANDO, re-reporta um barulho na
-- posicao do emitter a cada AudioRepeatInterval. Confiavel porque quem da :Play() nesses e o
-- proprio server (nao dependemos de nenhuma leitura de audio, que no server nao existe).
function NoiseService:BindAudioPlayer(audioPlayer: AudioPlayer, radius: number, map: Model?)
	if radius <= 0 then
		return
	end
	boundAudio[audioPlayer] = { Radius = radius, Map = map, NextAt = 0 }
end

-- Liga TODOS os AudioPlayers do mapa que tiverem o atributo "NoiseRadius" (number). Deixa o raio
-- autoravel no Studio: para um telefone/servidor do Office atrair o NPC, basta por o atributo no
-- AudioPlayer — sem codigo novo por puzzle.
function NoiseService:BindMapAudio(map: Model)
	local count = 0
	for _, descendant in map:GetDescendants() do
		if descendant:IsA("AudioPlayer") then
			local radius = descendant:GetAttribute("NoiseRadius")
			if typeof(radius) == "number" and radius > 0 then
				self:BindAudioPlayer(descendant, radius, map)
				count += 1
			end
		end
	end
	if count > 0 then
		print(string.format("[NoiseService] %d AudioPlayer(s) ligados como fonte de ruido em '%s'", count, map.Name))
	end
end

-- Solta os AudioPlayers de um mapa (chamado no OnUnload do MapBehavior).
function NoiseService:UnbindMap(map: Model)
	for audioPlayer, bound in boundAudio do
		if bound.Map == map then
			boundAudio[audioPlayer] = nil
		end
	end
end


--== Voz ======================================================================================

-- Reporte de nivel de microfone vindo do dono (VoiceNoiseController). NAO confiamos em nada alem
-- do numero: a posicao e sempre a do personagem do remetente no server.
local function onVoiceReported(player: Player, level: any)
	if not CONFIG.VoiceEnabled then
		return
	end
	-- Rejeita nao-numero, NaN e silencio.
	if typeof(level) ~= "number" or level ~= level or level <= 0 then
		return
	end

	local now = os.clock()
	local last = lastVoiceAt[player]
	if last and now - last < CONFIG.VoiceMinInterval then
		return
	end
	lastVoiceAt[player] = now

	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not rootPart then
		return
	end

	local radius = math.clamp(level * CONFIG.VoiceRadiusScale, 0, CONFIG.VoiceMaxRadius)
	NoiseService:Report(rootPart.Position, radius, "Voice", player)
end


--== Ciclo ====================================================================================

-- Poda eventos vencidos e re-reporta os AudioPlayers ligados que estao tocando.
local function step()
	local now = os.clock()

	-- Poda de tras para frente (remocao segura durante a varredura).
	for i = #events, 1, -1 do
		if now - events[i].Time > CONFIG.EventTTL then
			table.remove(events, i)
		end
	end

	for audioPlayer, bound in boundAudio do
		if not audioPlayer.Parent then
			boundAudio[audioPlayer] = nil
		elseif audioPlayer.IsPlaying and now >= bound.NextAt then
			bound.NextAt = now + CONFIG.AudioRepeatInterval
			local position = resolveAudioPosition(audioPlayer)
			if position then
				NoiseService:Report(position, bound.Radius, "Audio", nil)
			end
		end
	end
end


function NoiseService:Start()
	EnsureRemotes()

	ReportVoiceRemote.OnServerEvent:Connect(onVoiceReported)
	Players.PlayerRemoving:Connect(function(player)
		lastVoiceAt[player] = nil
	end)

	RunService.Heartbeat:Connect(step)

	print("✓ NoiseService initialized")
end


return NoiseService
