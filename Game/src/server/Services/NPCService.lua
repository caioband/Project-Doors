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

local NPCModules = ServerScriptService.Server.SharedModules.NPC
local NPCAgent = require(NPCModules.NPCAgent)
local NavGraph = require(NPCModules.NavGraph)
local BaseStates = require(NPCModules.BaseStates)

local NPCService = {}

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


-- Injeta no agente a capacidade de abrir portas no caminho: a lista de Knobs do mapa e uma funcao
-- que abre uma porta via DoorService. No-op se o DoorService nao estiver disponivel. 'knobs' pode
-- ser passado ja coletado (evita recolher para cada NPC do mapa).
function NPCService:_injectDoors(agent: any, map: Model, knobs: { BasePart }?)
	local doorService = self.GetService and self.GetService("DoorService")
	if not doorService then
		return
	end
	agent.DoorKnobs = knobs or CollectDoorKnobs(map)
	agent.OpenDoorFn = function(knob: BasePart)
		doorService:OpenDoor(knob)
	end
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

	local agents = {}
	for _, model in ipairs(modelsFolder:GetChildren()) do
		if model:IsA("Model") and model:FindFirstChildOfClass("Humanoid") then
			local behavior = ResolveBehavior(model.Name)

			local agent = NPCAgent.new(model, behavior and behavior.Config)
			agent.NavGraph = nav
			self:_injectDoors(agent, map, doorKnobs)
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
	self:_injectDoors(agent, map)
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
