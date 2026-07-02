--!strict
-- NPCAgent
-- Classe base (OOP, estilo SharedModules/Viewmodel) que envolve um Model humanoide de NPC e
-- expoe as PRIMITIVAS de comportamento base compartilhadas por todos os NPCs:
--   * Movimento com desvio de obstaculos (PathfindingService + Humanoid:MoveTo)
--   * Sensoriamento: player mais proximo, linha de visao (raycast) e distancias
--   * Animacoes de locomocao (walk/idle) carregadas do config
--   * Uma state machine simples (Idle/Patrol/Chase vem de BaseStates; NPCs podem registrar
--     estados proprios via NPCBehaviors/<Nome>.lua)
--
-- Server-autoritativo: o Humanoid e o pathfinding rodam no server e replicam para os clients
-- (SetNetworkOwner(nil)). O NPCAgent NAO cria loop proprio; quem chama :Update(dt) todo frame e
-- o NPCService (loop Heartbeat unico).
--
-- Gancho de contato: :OnReachPlayer (nil por padrao). Quando o NPC alcanca o player, o Chase
-- chama esse gancho se definido. Hoje e no-op (NPCs so se movem); e o ponto de extensao para
-- dano/pegar/jumpscare no futuro.

local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local NPCAgent = {}
NPCAgent.__index = NPCAgent

export type Animations = {
	Walk: string?,
	Idle: string?,
	Run: string?,
}

export type NPCConfig = {
	-- Velocidade de patrulha e de perseguicao (studs/s).
	WalkSpeed: number?,
	ChaseSpeed: number?,
	-- Deteccao: raio maximo (studs) e se exige linha de visao livre (raycast).
	DetectionRadius: number?,
	RequireLineOfSight: boolean?,
	-- Tempo (s) sem ver o alvo antes de desistir da perseguicao.
	LoseTargetTime: number?,
	-- Distancia (studs) considerada "alcancou o player" (dispara OnReachPlayer).
	ReachDistance: number?,
	-- Tempo de espera (s) parado no estado Idle antes de voltar a patrulhar.
	IdleTimeMin: number?,
	IdleTimeMax: number?,
	-- Distancia minima (studs) do proximo node de patrulha (evita repetir o node atual).
	PatrolMinNodeDist: number?,
	-- Intervalo (s) para recomputar o caminho ate o player durante a perseguicao.
	PathRecomputeInterval: number?,
	-- Intervalo (s) do sensoriamento (raycast/scan de players); nao roda todo frame.
	SenseInterval: number?,
	-- Ao spawnar, teleporta o NPC para um node aleatorio da NavGraph (evita modelos autorados
	-- flutuando fora do navmesh). Ver :_prepareModel.
	SpawnAtNode: boolean?,
	-- Altura (studs) acima do node ao teleportar (deixa o NPC cair/assentar no chao).
	SpawnHeightOffset: number?,
	-- Raio (studs) para abrir portas a frente no caminho (ver :_scanDoors). So age se o abridor
	-- de portas tiver sido injetado pelo NPCService.
	DoorOpenRadius: number?,
	-- Intervalo (s) do scan de portas (nao roda todo frame).
	DoorScanInterval: number?,
	-- IDs das animacoes de locomocao ("rbxassetid://..."); vazio = anda sem animacao.
	Animations: Animations?,
	-- Parametros do PathfindingService:CreatePath.
	AgentParams: { [string]: any }?,
}

local DEFAULT_CONFIG: NPCConfig = {
	WalkSpeed = 10,
	ChaseSpeed = 16,
	DetectionRadius = 40,
	RequireLineOfSight = true,
	LoseTargetTime = 4,
	ReachDistance = 4,
	IdleTimeMin = 0.75,
	IdleTimeMax = 2.5,
	PatrolMinNodeDist = 20,
	PathRecomputeInterval = 0.5,
	SenseInterval = 0.2,
	SpawnAtNode = true,
	SpawnHeightOffset = 3,
	DoorOpenRadius = 18,
	DoorScanInterval = 0.3,
	Animations = {},
	AgentParams = {
		AgentRadius = 3,
		AgentHeight = 5,
		AgentCanJump = true,
		WaypointSpacing = 4,
		-- Custos por PathfindingModifier: areas marcadas com o modifier "Obstacle" sao evitadas
		-- pelo pathfinding (custo infinito).
		Costs = {
			Obstacle = math.huge,
		},
	},
}

-- Mescla config do usuario sobre os defaults (um nivel de aninhamento para Animations/AgentParams).
local function mergeConfig(config: NPCConfig?): NPCConfig
	local merged: any = {}
	for key, value in pairs(DEFAULT_CONFIG) do
		if typeof(value) == "table" then
			local copy = {}
			for k, v in pairs(value :: any) do
				copy[k] = v
			end
			merged[key] = copy
		else
			merged[key] = value
		end
	end
	if config then
		for key, value in pairs(config :: any) do
			if typeof(value) == "table" and typeof(merged[key]) == "table" then
				for k, v in pairs(value) do
					merged[key][k] = v
				end
			else
				merged[key] = value
			end
		end
	end
	return merged
end

-- Cria um agente para um Model humanoide (ainda nao inicia; ver :Start).
function NPCAgent.new(model: Model, config: NPCConfig?)
	local self = setmetatable({}, NPCAgent)

	self.Model = model
	self.Config = mergeConfig(config)
	self.Humanoid = model:FindFirstChildOfClass("Humanoid")
	self.RootPart = (model.PrimaryPart or model:FindFirstChild("HumanoidRootPart")) :: BasePart?

	-- State machine: nome -> { OnEnter?, OnUpdate?, OnExit? }. StateData e o rascunho do estado atual.
	self.States = {} :: { [string]: any }
	self.State = nil :: any
	self.StateName = nil :: string?
	self.StateData = {} :: { [string]: any }

	-- Memoria compartilhada entre estados deste agente (ex.: Target = Player perseguido).
	self.Blackboard = {} :: { [string]: any }

	-- Injetado pelo NPCService: rede de patrulha (AINodes) deste mapa.
	self.NavGraph = nil :: any

	-- Injetados pelo NPCService (opcionais): abertura de portas no caminho. DoorKnobs e a lista
	-- de Knobs de porta do mapa; OpenDoorFn(knob) abre a porta (via DoorService). Ver :_scanDoors.
	self.DoorKnobs = nil :: { BasePart }?
	self.OpenDoorFn = nil :: ((BasePart) -> ())?
	self._doorAccum = 0

	-- Gancho de contato (stub) — ver cabecalho.
	self.OnReachPlayer = nil :: ((any, Player) -> ())?

	-- Movimento: token invalida jobs de movimento anteriores; MoveStatus e lido pelos estados.
	self._moveToken = 0
	self.MoveStatus = "idle" -- idle | moving | reached | failed

	-- Sensoriamento (throttle).
	self._senseAccum = 0
	self._lastSensed = nil :: Player?

	-- Tracks de animacao de locomocao por nome (Walk/Idle/Run) e a track ativa no momento.
	self._tracks = {} :: { [string]: AnimationTrack }
	self._activeTrack = nil :: AnimationTrack?

	self._alive = true

	return self
end

-- Carrega as animacoes de locomocao do config no Animator do Humanoid (silencioso se faltarem).
function NPCAgent:_setupAnimations()
	local humanoid = self.Humanoid
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return
	end
	for name, id in pairs(self.Config.Animations or {}) do
		if typeof(id) == "string" and id ~= "" then
			local anim = Instance.new("Animation")
			anim.AnimationId = id
			local ok, track = pcall(function()
				return animator:LoadAnimation(anim)
			end)
			if ok and track then
				-- Looping/Priority sao best-effort: em alguns casos o loop ja vem do proprio asset
				-- (setado no editor de animacao) e setar aqui pode nao ser suportado; nunca deve
				-- quebrar o spawn do NPC.
				pcall(function()
					track.Looping = true
					track.Priority = Enum.AnimationPriority.Movement
				end)
				self._tracks[name] = track

				-- Fallback de loop: se o engine/asset nao mantiver o loop (a propriedade Looping
				-- pode nao ser suportada), re-toca a track ao terminar enquanto ela for a ativa.
				-- Length > 0 evita tight-loop caso o asset nao carregue.
				track.Stopped:Connect(function()
					if self._alive and self._activeTrack == track and track.Length > 0 then
						track:Play(0)
					end
				end)
			else
				warn(string.format("[NPCAgent] Falha ao carregar animacao '%s' (%s) em '%s'",
					name, tostring(id), self.Model.Name))
			end
		end
	end
end

-- Toca a track de locomocao 'name' (Walk/Idle/Run) e para as demais. Sem-efeito se nao existir.
-- Marca a track ativa para o fallback de loop (ver :_setupAnimations) so re-tocar a track certa.
function NPCAgent:PlayLocomotion(name: string)
	self._activeTrack = self._tracks[name]
	for trackName, track in pairs(self._tracks) do
		if trackName == name then
			if not track.IsPlaying then
				track:Play(0.15)
			end
		elseif track.IsPlaying then
			track:Stop(0.15)
		end
	end
end

-- Prepara o Model para andar como NPC dinamico. NPCs autorados no mapa costumam vir ancorados
-- (para nao derivar na edicao). Aqui: desancora tudo e teleporta o NPC para um node de patrulha
-- (evita spawnar flutuando fora do navmesh). Chamado no inicio de :Start.
--
-- A COLISAO NAO e mexida aqui: fica como autorada no modelo (ex.: colisao no Secretary.corpo e
-- HumanoidRootPart com CanCollide=false).
function NPCAgent:_prepareModel()
	for _, part in ipairs(self.Model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = false
		end
	end

	if self.Config.SpawnAtNode and self.NavGraph then
		local node = self.NavGraph:GetRandomNode()
		if node then
			self.Model:PivotTo(CFrame.new(node.Position + Vector3.new(0, self.Config.SpawnHeightOffset, 0)))
		end
	end
end

-- Inicia o agente: prepara o Model (desancora/decolide/teleporta para um node), fixa o network
-- owner no server, aplica WalkSpeed, carrega animacoes e entra no estado inicial (default "Idle").
function NPCAgent:Start(startState: string?)
	self:_prepareModel()

	if self.RootPart then
		pcall(function()
			(self.RootPart :: any):SetNetworkOwner(nil)
		end)
	end
	if self.Humanoid then
		self.Humanoid.WalkSpeed = self.Config.WalkSpeed
	end
	self:_setupAnimations()
	self:SetState(startState or "Idle")
end

--== State machine ============================================================================

-- Registra um unico estado.
function NPCAgent:RegisterState(name: string, state: any)
	self.States[name] = state
end

-- Registra varios estados de uma vez (ex.: BaseStates, depois overrides do behavior).
function NPCAgent:RegisterStates(states: { [string]: any })
	for name, state in pairs(states) do
		self.States[name] = state
	end
end

-- Troca de estado: OnExit do anterior -> zera StateData -> OnEnter do novo.
function NPCAgent:SetState(name: string)
	if self.StateName == name then
		return
	end
	local prev = self.State
	if prev and prev.OnExit then
		prev.OnExit(self)
	end
	local nextState = self.States[name]
	if not nextState then
		warn(string.format("[NPCAgent] Estado '%s' nao registrado em '%s'", name, self.Model.Name))
		return
	end
	self.StateName = name
	self.State = nextState
	self.StateData = {}
	if nextState.OnEnter then
		nextState.OnEnter(self)
	end
end

-- Chamado todo frame pelo NPCService. Aborta se o NPC foi destruido/morreu.
function NPCAgent:Update(dt: number)
	if not self._alive then
		return
	end
	if not self.RootPart or not self.RootPart.Parent then
		return
	end
	if self.Humanoid and self.Humanoid.Health <= 0 then
		return
	end
	if self.State and self.State.OnUpdate then
		self.State.OnUpdate(self, dt)
	end

	self:_scanDoors(dt)
end

-- Abre portas no caminho: a cada DoorScanInterval, procura Knobs de porta (DoorKnobs, injetados
-- pelo NPCService) dentro de DoorOpenRadius e a frente do movimento, e manda abrir (OpenDoorFn).
-- O DoorService so abre se estiver fechada, entao chamar repetido e barato/idempotente. No-op se
-- o abridor/lista nao foram injetados.
function NPCAgent:_scanDoors(dt: number)
	if not (self.OpenDoorFn and self.DoorKnobs and self.RootPart) then
		return
	end
	self._doorAccum += dt
	if self._doorAccum < self.Config.DoorScanInterval then
		return
	end
	self._doorAccum = 0

	local npcPos = self.RootPart.Position
	local moveDir = self.Humanoid and self.Humanoid.MoveDirection or Vector3.zero
	local moving = moveDir.Magnitude > 0.1
	local radius = self.Config.DoorOpenRadius

	for _, knob in ipairs(self.DoorKnobs) do
		if knob.Parent then
			local toDoor = knob.Position - npcPos
			local dist = toDoor.Magnitude
			if dist <= radius then
				-- So abre portas a frente (evita abrir as que ja ficaram para tras). Muito perto
				-- (metade do raio) abre de qualquer jeito, para nao ficar preso encostado nela.
				if not moving or dist <= radius * 0.5 or moveDir.Unit:Dot(toDoor.Unit) >= 0 then
					self.OpenDoorFn(knob)
				end
			end
		end
	end
end

--== Movimento ================================================================================

-- Computa um caminho ate 'dest' (nil se falhar). Sincrono (ComputeAsync yield-a).
function NPCAgent:_computePath(dest: Vector3): Path?
	local path = PathfindingService:CreatePath(self.Config.AgentParams)
	local ok = pcall(function()
		path:ComputeAsync((self.RootPart :: BasePart).Position, dest)
	end)
	if ok and path.Status == Enum.PathStatus.Success then
		return path
	end
	return nil
end

-- Percorre UM trecho: computa o caminho ate 'dest' (PathfindingService) e segue seus waypoints
-- com Humanoid:MoveTo. Yielda ate concluir. 'token' casa com self._moveToken para cancelamento.
-- Retorna "reached" | "failed" | "cancelled".
function NPCAgent:_walkLeg(dest: Vector3, token: number): string
	local path = self:_computePath(dest)
	if not path then
		-- Sem rota no navmesh. No MESMO nivel isso e tipicamente uma porta fechada bloqueando o
		-- pathfinding: avanca em LINHA RETA na direcao do alvo para encostar na porta; o :_scanDoors
		-- a abre e o proximo recalculo (Chase/Hunt refazem o path a cada PathRecomputeInterval) ja
		-- acha rota pela porta aberta. Se o alvo estiver em outro nivel/area desconectada (grande
		-- diferenca de Y), NAO marcha as cegas — isso levaria o NPC a andar reto para fora do mapa
		-- e cair. Nesse caso desiste do trecho (fica parado / a patrulha escolhe outro node).
		if math.abs(dest.Y - (self.RootPart :: BasePart).Position.Y) > 25 then
			return "failed"
		end
		self.Humanoid:MoveTo(dest)
		self.Humanoid.MoveToFinished:Wait()
		if token ~= self._moveToken or not self._alive then
			return "cancelled"
		end
		return "failed"
	end

	local waypoints = path:GetWaypoints()
	-- waypoints[1] e a posicao atual; comeca do 2.
	for i = 2, #waypoints do
		if token ~= self._moveToken or not self._alive then
			return "cancelled"
		end
		local wp = waypoints[i]
		if wp.Action == Enum.PathWaypointAction.Jump then
			self.Humanoid.Jump = true
		end
		self.Humanoid:MoveTo(wp.Position)
		local reached = self.Humanoid.MoveToFinished:Wait()
		if token ~= self._moveToken or not self._alive then
			return "cancelled"
		end
		if not reached then
			return "failed"
		end
	end

	return "reached"
end

-- Move o NPC ate 'dest' desviando de obstaculos (PathfindingService puro). Nao bloqueia: dispara
-- um job (token cancela o anterior) e atualiza self.MoveStatus, lido pelos estados. Usado pela
-- patrulha (destino = node) e pela perseguicao Chase/Hunt (destino = posicao do player).
function NPCAgent:MoveToPosition(dest: Vector3)
	if not (self.Humanoid and self.RootPart) then
		self.MoveStatus = "failed"
		return
	end
	self._moveToken += 1
	local token = self._moveToken
	self.MoveStatus = "moving"

	task.spawn(function()
		local result = self:_walkLeg(dest, token)
		if token ~= self._moveToken then
			return
		end
		if result == "reached" then
			self.MoveStatus = "reached"
		elseif result == "failed" then
			self.MoveStatus = "failed"
		end
	end)
end

-- Cancela o movimento atual e para o NPC no lugar.
function NPCAgent:Stop()
	self._moveToken += 1
	self.MoveStatus = "idle"
	if self.Humanoid and self.RootPart then
		self.Humanoid:MoveTo(self.RootPart.Position)
	end
end

--== Sensoriamento ============================================================================

-- Distancia (studs) da root do NPC a uma posicao.
function NPCAgent:DistanceTo(position: Vector3): number
	if not self.RootPart then
		return math.huge
	end
	return (self.RootPart.Position - position).Magnitude
end

-- Player vivo mais proximo dentro de 'radius' (retorna Player? e distancia).
function NPCAgent:GetNearestPlayer(radius: number): (Player?, number)
	local best: Player? = nil
	local bestDist = math.huge
	for _, player in ipairs(Players:GetPlayers()) do
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if hrp and hum and hum.Health > 0 then
			local d = self:DistanceTo(hrp.Position)
			if d <= radius and d < bestDist then
				best = player
				bestDist = d
			end
		end
	end
	return best, bestDist
end

-- Ha linha de visao livre da "cabeca" do NPC ate o HumanoidRootPart do player? Raycast ignorando
-- o proprio Model: ve se nao houver obstaculo ou se o primeiro hit pertencer ao char do player.
function NPCAgent:HasLineOfSight(player: Player): boolean
	local char = player.Character
	local targetHrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not targetHrp then
		return false
	end
	local head = self.Model:FindFirstChild("Head") or self.RootPart
	if not head then
		return false
	end
	local origin = (head :: BasePart).Position
	local direction = targetHrp.Position - origin

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { self.Model }

	local result = Workspace:Raycast(origin, direction, params)
	if not result then
		return true
	end
	return result.Instance:IsDescendantOf(char)
end

-- Deteccao base (throttled por SenseInterval): retorna o player detectado (dentro do raio e, se
-- RequireLineOfSight, com visao livre) ou nil. Entre os intervalos devolve o ultimo resultado.
function NPCAgent:Sense(dt: number): Player?
	self._senseAccum += dt
	if self._senseAccum < self.Config.SenseInterval then
		return self._lastSensed
	end
	self._senseAccum = 0

	local player = self:GetNearestPlayer(self.Config.DetectionRadius)
	if player and self.Config.RequireLineOfSight and not self:HasLineOfSight(player) then
		player = nil
	end
	self._lastSensed = player
	return player
end

--== Ciclo de vida ============================================================================

-- Encerra o agente: cancela movimento, para/limpa animacoes e destroi o Model do NPC.
function NPCAgent:Destroy()
	self._alive = false
	self._moveToken += 1
	for _, track in pairs(self._tracks) do
		track:Stop()
		track:Destroy()
	end
	self._tracks = {}
	if self.Model then
		self.Model:Destroy()
	end
end

return NPCAgent
