--!strict
-- NPCService
-- Orquestra os NPCs de cada mapa. Auto-descoberto por Services/init.server.lua (:Init/:Start,
-- com GetService injetado).
--
-- Fluxo (chamado pelo MapBehavior do mapa):
--   * :SpawnForMap(ctx)  - le ctx.Map.AIModels; para cada Model humanoide resolve a logica unica
--                          em SharedModules.NPC.NPCBehaviors.<Model.Name> (fallback: so base),
--                          instancia um NPCAgent com NavGraph de ctx.Map.AINodes e o inicia.
--   * :ClearForMap(map)  - destroi todos os agentes daquele mapa (evita loops/paths orfaos ao
--                          trocar de rodada).
--
-- Um unico loop RunService.Heartbeat atualiza todos os agentes ativos (o NPCAgent nao cria loop
-- proprio). Server-autoritativo: Humanoid + pathfinding replicam para os clients.

local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local NPCModules = ServerScriptService.Server.SharedModules.NPC
local NPCAgent = require(NPCModules.NPCAgent)
local NavGraph = require(NPCModules.NavGraph)
local BaseStates = require(NPCModules.BaseStates)

local NPCService = {}

-- Remote que avisa TODOS os clients quando um NPC entra/sai do modo caca. Disparado com
-- (npcModel: Model, isHunting: boolean). O client (HuntSensesController) usa para ligar/desligar o
-- heartbeat/respiracao e o tremor de camera, com intensidade pela proximidade do NPC mais proximo.
local HuntStateRemote: RemoteEvent

-- Garante a hierarquia ReplicatedStorage.Comms.NPC e o remote de estado de caca.
local function EnsureRemotes()
	local comms = ReplicatedStorage:FindFirstChild("Comms")
	if not comms then
		comms = Instance.new("Folder")
		comms.Name = "Comms"
		comms.Parent = ReplicatedStorage
	end
	local npc = comms:FindFirstChild("NPC")
	if not npc then
		npc = Instance.new("Folder")
		npc.Name = "NPC"
		npc.Parent = comms
	end
	HuntStateRemote = npc:FindFirstChild("HuntState") :: RemoteEvent
	if not HuntStateRemote then
		HuntStateRemote = Instance.new("RemoteEvent")
		HuntStateRemote.Name = "HuntState"
		HuntStateRemote.Parent = npc
	end
end

-- Pasta com os descritores de logica unica por nome de NPC.
local BehaviorsFolder = NPCModules:FindFirstChild("NPCBehaviors")

-- Agentes ativos por mapa: [Model do mapa] -> { NPCAgent }.
local ActiveByMap: { [Model]: { any } } = {}


-- Resolve o descritor de comportamento unico de um NPC pelo nome (nil se nao houver / erro).
local function ResolveBehavior(name: string): any
	if not BehaviorsFolder then
		return nil
	end
	local module = BehaviorsFolder:FindFirstChild(name)
	if not module or not module:IsA("ModuleScript") then
		return nil
	end
	local ok, result = pcall(require, module)
	if not ok then
		warn(string.format("[NPCService] Falha ao carregar behavior '%s': %s", name, tostring(result)))
		return nil
	end
	return result
end


-- Localiza um Model de NPC em map.AIModels pelo nome (nil se nao existir).
local function FindNPCModel(map: Model, name: string): Model?
	local folder = map:FindFirstChild("AIModels")
	local model = folder and folder:FindFirstChild(name)
	if model and model:IsA("Model") then
		return model :: Model
	end
	return nil
end


-- Esconde/revela um Model dormente. Escondido: ancora, torna invisivel e nao-colidivel (guardando
-- transparencia e CanCollide ORIGINAIS por atributo). Revelar restaura ambos aos valores autorados
-- (a colisao do NPC e definida no modelo, ex.: no Secretary.corpo). Desancorar fica com o
-- NPCAgent:_prepareModel ao iniciar o agente.
local function SetModelHidden(model: Model, hidden: boolean)
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			if hidden then
				if part:GetAttribute("NPCOrigTransparency") == nil then
					part:SetAttribute("NPCOrigTransparency", part.Transparency)
				end
				if part:GetAttribute("NPCOrigCanCollide") == nil then
					part:SetAttribute("NPCOrigCanCollide", part.CanCollide)
				end
				part.Anchored = true
				part.CanCollide = false
				part.Transparency = 1
			else
				local origTransparency = part:GetAttribute("NPCOrigTransparency")
				if origTransparency ~= nil then
					part.Transparency = origTransparency :: number
				end
				local origCanCollide = part:GetAttribute("NPCOrigCanCollide")
				if origCanCollide ~= nil then
					part.CanCollide = origCanCollide :: boolean
				end
			end
		end
	end
end


-- Registra um agente sob um mapa (append; cria a lista se necessario).
local function TrackAgent(map: Model, agent: any)
	local list = ActiveByMap[map]
	if not list then
		list = {}
		ActiveByMap[map] = list
	end
	table.insert(list, agent)
end


-- Coleta os Knobs das portas do mapa (mesmo criterio do DoorService: ProximityPrompt com atributo
-- "IsDoor" cujo parent e uma BasePart "Knob"). Usado para o NPC abrir portas no caminho.
local function CollectDoorKnobs(map: Model): { BasePart }
	local knobs: { BasePart } = {}
	for _, d in ipairs(map:GetDescendants()) do
		if d:IsA("ProximityPrompt") and d:GetAttribute("IsDoor") == true then
			local knob = d.Parent
			if knob and knob:IsA("BasePart") and knob.Name == "Knob" then
				table.insert(knobs, knob)
			end
		end
	end
	return knobs
end


-- Injeta no agente a capacidade de lidar com portas no caminho: a lista de Knobs do mapa, uma funcao
-- que abre uma porta e outra que consulta se ela esta fechada (ambas via DoorService). No-op se o
-- DoorService nao estiver disponivel. 'knobs' pode ser passado ja coletado (evita recolher por NPC).
-- O IsDoorClosedFn permite ao NPC, quando o pathfinding da NoPath (porta fechada bloqueia o navmesh),
-- escolher a porta FECHADA que esta no caminho e ir abri-la. Ver NPCAgent:_pickBlockingDoor.
function NPCService:_injectDoors(agent: any, map: Model, knobs: { BasePart }?)
	local doorService = self.GetService and self.GetService("DoorService")
	if not doorService then
		return
	end
	agent.DoorKnobs = knobs or CollectDoorKnobs(map)
	agent.OpenDoorFn = function(knob: BasePart)
		doorService:OpenDoor(knob)
	end
	agent.IsDoorClosedFn = function(knob: BasePart)
		return not doorService:IsOpen(knob)
	end
end


-- Injeta no agente o sinal de mudanca de modo caca: quando o NPC entra/sai de Hunt (via
-- NPCAgent:SetHunting), avisa TODOS os clients com (model, isHunting). Serve para qualquer NPC.
function NPCService:_injectHuntSignal(agent: any)
	agent.OnHuntChanged = function(isHunting: boolean)
		if HuntStateRemote then
			HuntStateRemote:FireAllClients(agent.Model, isHunting)
		end
	end
end


-- Parametros da escolha de um ponto de spawn FORA do campo de visao dos players.
local SPAWN_SIGHT = {
	-- Alem desta distancia consideramos que o player nao notaria o spawn, mesmo de frente.
	SightRange = 140,
	-- Nunca spawna a menos disso de um player, mesmo com parede no meio (sairia "do nada" ao lado).
	HardMinDistance = 30,
	-- Dot minimo entre o LookVector do player e a direcao do ponto para contar como "de frente".
	-- 0.2 ~= 78 graus para cada lado — conservador de proposito (na duvida, considera visivel).
	FovDot = 0.2,
	-- Altura (studs) do "olho" do player e do ponto testado, para o raycast nao rasar o chao.
	EyeHeight = 2,
}


-- Um player VE este ponto? Combina distancia, orientacao e parede:
--   * mais perto que HardMinDistance          -> visivel (perto demais, independente de tudo)
--   * mais longe que SightRange               -> nao visivel
--   * atras do player (a RootPart acompanha a camera com AutoRotate) -> nao visivel
--   * qualquer geometria COLIDIVEL no caminho -> nao visivel
-- Na duvida retorna true (preferimos descartar um node bom a spawnar na cara de alguem).
local function IsPointVisibleTo(position: Vector3, player: Player, ignore: { Instance }): boolean
	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	-- Player morto/sem personagem nao ve nada (nao deve travar a escolha do ponto).
	if not rootPart or not humanoid or humanoid.Health <= 0 then
		return false
	end

	local eye = rootPart.Position + Vector3.new(0, SPAWN_SIGHT.EyeHeight, 0)
	local target = position + Vector3.new(0, SPAWN_SIGHT.EyeHeight, 0)
	local delta = target - eye
	local dist = delta.Magnitude

	if dist <= SPAWN_SIGHT.HardMinDistance then
		return true
	end
	if dist > SPAWN_SIGHT.SightRange then
		return false
	end
	if delta.Unit:Dot(rootPart.CFrame.LookVector) < SPAWN_SIGHT.FovDot then
		return false
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	params.IgnoreWater = true
	-- CRUCIAL: sem isto, as parts marcadoras nao-colidiveis do mapa (ex.: PathfindingObstacles)
	-- bloqueiam o raycast e TODO node pareceria escondido, tornando a checagem inutil.
	pcall(function()
		(params :: any).RespectCanCollide = true
	end)

	return Workspace:Raycast(eye, delta, params) == nil
end


-- Escolhe um AINode que NENHUM player vivo esteja vendo (aleatorio entre os candidatos, para o
-- spawn nao ser sempre no mesmo canto). Se todos os nodes estiverem a vista, cai no MAIS DISTANTE
-- do player mais proximo — o menos ruim.
function NPCService:_pickHiddenNode(nav: any, model: Model?): Vector3?
	local nodes = nav and nav.Nodes
	if not nodes or #nodes == 0 then
		return nil
	end

	-- O raycast de visao ignora os personagens (queremos parede, nao corpo) e o proprio NPC.
	local ignore: { Instance } = {}
	if model then
		table.insert(ignore, model)
	end
	local players = Players:GetPlayers()
	for _, player in players do
		if player.Character then
			table.insert(ignore, player.Character)
		end
	end

	local hidden: { Vector3 } = {}
	local fallback: Vector3? = nil
	local fallbackDist = -1

	for _, node in nodes do
		local position = node.Position

		local visible = false
		local nearest = math.huge
		for _, player in players do
			local rootPart = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if rootPart then
				nearest = math.min(nearest, (rootPart.Position - position).Magnitude)
			end
			if IsPointVisibleTo(position, player, ignore) then
				visible = true
				break
			end
		end

		if not visible then
			table.insert(hidden, position)
		elseif nearest > fallbackDist then
			-- Guarda o "menos pior" caso nenhum node escape da visao de todos.
			fallback = position
			fallbackDist = nearest
		end
	end

	if #hidden > 0 then
		return hidden[math.random(#hidden)]
	end
	return fallback
end


-- Injeta no agente a AUDICAO: a consulta ao NoiseService usada por NPCAgent:Hear. Sem isso o NPC
-- fica surdo (o :Hear devolve nil sempre) — os NPCs que cacam por visao nem notam.
function NPCService:_injectNoise(agent: any)
	local noiseService = self.GetService and self.GetService("NoiseService")
	if not noiseService then
		return
	end
	agent.QueryNoiseFn = function(position: Vector3, multiplier: number, sinceTime: number, ignore: Instance?)
		return noiseService:Query(position, multiplier, sinceTime, ignore)
	end
end


-- Coleta as BaseParts do mapa marcadas com um PathfindingModifier de Label "Obstacle". O NPC as
-- respeita no fallback de linha reta (nao atravessa), ja que elas sao CanCollide=false e nao
-- barram fisicamente. Ver NPCAgent:_pathCrossesObstacle.
local function CollectObstacleParts(map: Model): { BasePart }
	local parts: { BasePart } = {}
	for _, d in ipairs(map:GetDescendants()) do
		if d:IsA("PathfindingModifier") and d.Label == "Obstacle" then
			local part = d.Parent
			if part and part:IsA("BasePart") then
				table.insert(parts, part)
			end
		end
	end
	return parts
end


-- Spawna e inicia os NPCs de um mapa recem-carregado. ctx e o BehaviorContext do RoundService.
function NPCService:SpawnForMap(ctx: any)
	local map = ctx.Map
	local modelsFolder = map:FindFirstChild("AIModels")
	if not modelsFolder then
		-- Mapa sem NPCs: nada a fazer.
		return
	end
	local nodesFolder = map:FindFirstChild("AINodes")
	local nav = NavGraph.new(nodesFolder)
	local doorKnobs = CollectDoorKnobs(map)
	local obstacleParts = CollectObstacleParts(map)

	local agents = {}
	for _, model in ipairs(modelsFolder:GetChildren()) do
		if model:IsA("Model") and model:FindFirstChildOfClass("Humanoid") then
			local behavior = ResolveBehavior(model.Name)

			local agent = NPCAgent.new(model, behavior and behavior.Config)
			agent.NavGraph = nav
			agent.ObstacleParts = obstacleParts
			self:_injectDoors(agent, map, doorKnobs)
			self:_injectHuntSignal(agent)
			self:_injectNoise(agent)
			agent:RegisterStates(BaseStates)
			if behavior and behavior.States then
				agent:RegisterStates(behavior.States)
			end
			agent:Start(behavior and behavior.StartState or "Idle")

			table.insert(agents, agent)
		end
	end

	ActiveByMap[map] = agents
	print(string.format(
		"[NPCService] %d NPC(s) spawnados para '%s' (%d nodes de patrulha)",
		#agents, tostring(ctx.MapName), nav:Count()
	))
end


-- Deixa um NPC dormente (escondido/ancorado) na carga do mapa, para ser spawnado depois sob
-- demanda (ex.: Secretary, spawnado so quando o puzzle do monitor falha). Ver :SpawnHunter.
function NPCService:HideNPCInMap(map: Model, name: string)
	local model = FindNPCModel(map, name)
	if model then
		SetModelHidden(model, true)
	end
end


-- Spawna um NPC como CACADOR: revela o Model, cria o agente com sua logica unica e o inicia no
-- estado "Hunt" (persegue implacavelmente o targetPlayer; se nil/sumir, caca o mais proximo).
-- Usado quando um NPC dormente entra em acao (ex.: Secretary apos a falha do puzzle do Office).
function NPCService:SpawnHunter(map: Model, name: string, targetPlayer: Player?)
	local model = FindNPCModel(map, name)
	if not model then
		warn(string.format("[NPCService] SpawnHunter: NPC '%s' nao encontrado em %s.AIModels", name, map:GetFullName()))
		return
	end

	SetModelHidden(model, false) -- revela antes do agente teleportar/iniciar

	local behavior = ResolveBehavior(name)
	local agent = NPCAgent.new(model, behavior and behavior.Config)
	agent.NavGraph = NavGraph.new(map:FindFirstChild("AINodes"))
	agent.ObstacleParts = CollectObstacleParts(map)
	self:_injectDoors(agent, map)
	self:_injectHuntSignal(agent)
	self:_injectNoise(agent)
	agent:RegisterStates(BaseStates)
	if behavior and behavior.States then
		agent:RegisterStates(behavior.States)
	end
	if targetPlayer then
		agent.Blackboard.Target = targetPlayer
	end
	agent:Start("Hunt")

	TrackAgent(map, agent)
	print(string.format("[NPCService] Hunter '%s' spawnado em %s (alvo=%s)",
		name, map:GetFullName(), tostring(targetPlayer)))
end


-- Spawna um NPC dormente no estado PADRAO do behavior dele (nao em Hunt, como o :SpawnHunter), num
-- AINode que nenhum player esteja vendo. Usado para o NPC "aparecer no meio da rodada" sem que
-- ninguem veja o modelo surgir do nada (ver o BusinessMan em MapBehaviors/Office).
--
-- Se nao houver nenhum node livre de olhares, usa o mais distante do player mais proximo em vez de
-- desistir: melhor um spawn discutivel do que a rodada sem NPC.
-- Retorna true se spawnou.
function NPCService:SpawnHidden(map: Model, name: string): boolean
	local model = FindNPCModel(map, name)
	if not model then
		warn(string.format("[NPCService] SpawnHidden: NPC '%s' nao encontrado em %s.AIModels", name, map:GetFullName()))
		return false
	end

	local nav = NavGraph.new(map:FindFirstChild("AINodes"))
	local spawnPosition = self:_pickHiddenNode(nav, model)

	SetModelHidden(model, false) -- revela antes do agente teleportar/iniciar

	local behavior = ResolveBehavior(name)
	local agent = NPCAgent.new(model, behavior and behavior.Config)
	agent.NavGraph = nav
	agent.ObstacleParts = CollectObstacleParts(map)
	agent.SpawnPosition = spawnPosition -- nil => cai no sorteio normal de node
	self:_injectDoors(agent, map)
	self:_injectHuntSignal(agent)
	self:_injectNoise(agent)
	agent:RegisterStates(BaseStates)
	if behavior and behavior.States then
		agent:RegisterStates(behavior.States)
	end
	agent:Start(behavior and behavior.StartState or "Idle")

	TrackAgent(map, agent)
	print(string.format("[NPCService] '%s' spawnado em %s (estado=%s, pos=%s)",
		name, map:GetFullName(), tostring(behavior and behavior.StartState or "Idle"),
		spawnPosition and tostring(spawnPosition) or "node aleatorio"))
	return true
end


-- Destroi os agentes de um mapa (chamado no OnUnload do MapBehavior).
function NPCService:ClearForMap(map: Model)
	local agents = ActiveByMap[map]
	if not agents then
		return
	end
	for _, agent in ipairs(agents) do
		agent:Destroy()
	end
	ActiveByMap[map] = nil
end


function NPCService:Start()
	EnsureRemotes()

	-- Loop unico: atualiza a state machine de cada agente ativo todo frame.
	RunService.Heartbeat:Connect(function(dt: number)
		for _, agents in pairs(ActiveByMap) do
			for _, agent in ipairs(agents) do
				agent:Update(dt)
			end
		end
	end)
end


return NPCService
