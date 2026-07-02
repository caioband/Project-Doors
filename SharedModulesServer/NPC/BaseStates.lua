--!strict
-- BaseStates
-- Comportamentos BASE reutilizaveis por todos os NPCs, como estados de uma state machine.
-- Cada estado e uma tabela { OnEnter?, OnUpdate?, OnExit? } que recebe o NPCAgent (self) e le
-- os thresholds de agent.Config. Um NPC especifico (NPCBehaviors/<Nome>.lua) pode sobrescrever
-- qualquer um destes ou adicionar novos.
--
--   * Idle   - parado (anim idle) por um tempo; ao expirar vai patrulhar. Detecta player -> Chase.
--   * Patrol - anda entre os AINodes (NavGraph). Ao chegar, volta a Idle (pausa natural entre
--              nodes). Detecta player -> Chase.
--   * Chase  - segue o player detectado (blackboard.Target), recomputando o caminho. Perde a
--              visao/distancia por LoseTargetTime s -> volta a Patrol. Ao alcancar, chama o
--              gancho OnReachPlayer (stub; NPCs so se movem por enquanto).

local BaseStates = {}

--== Idle =====================================================================================

BaseStates.Idle = {
	OnEnter = function(agent: any)
		agent:Stop()
		agent:PlayLocomotion("Idle")
		agent.StateData.timer = 0
		agent.StateData.wait = agent.Config.IdleTimeMin
			+ math.random() * math.max(agent.Config.IdleTimeMax - agent.Config.IdleTimeMin, 0)
	end,

	OnUpdate = function(agent: any, dt: number)
		local target = agent:Sense(dt)
		if target then
			agent.Blackboard.Target = target
			agent:SetState("Chase")
			return
		end

		agent.StateData.timer += dt
		if agent.StateData.timer >= agent.StateData.wait then
			agent:SetState("Patrol")
		end
	end,
}

--== Patrol ===================================================================================

BaseStates.Patrol = {
	OnEnter = function(agent: any)
		if agent.Humanoid then
			agent.Humanoid.WalkSpeed = agent.Config.WalkSpeed
		end
		agent:PlayLocomotion("Walk")
		-- Sinaliza que precisa escolher um node no primeiro update.
		agent.StateData.needTarget = true
	end,

	OnUpdate = function(agent: any, dt: number)
		local target = agent:Sense(dt)
		if target then
			agent.Blackboard.Target = target
			agent:SetState("Chase")
			return
		end

		if agent.StateData.needTarget then
			agent.StateData.needTarget = false
			local node = agent.NavGraph
				and agent.NavGraph:GetRandomNodeAwayFrom(agent.RootPart.Position, agent.Config.PatrolMinNodeDist)
			if node then
				agent:MoveToPosition(node.Position)
			else
				-- Sem grafo/nodes: nao ha para onde patrulhar, so fica em Idle.
				agent:SetState("Idle")
			end
			return
		end

		if agent.MoveStatus == "reached" then
			-- Chegou no node: pausa em Idle (que depois volta a patrulhar em outro node).
			agent:SetState("Idle")
		elseif agent.MoveStatus == "failed" then
			-- Caminho falhou/bloqueou: tenta outro node.
			agent.StateData.needTarget = true
		end
	end,
}

--== Chase ====================================================================================

-- Alvo ainda valido (existe, char presente, vivo)? Retorna o HumanoidRootPart ou nil.
local function targetRoot(target: Player?): BasePart?
	local char = target and target.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hrp and hum and hum.Health > 0 then
		return hrp
	end
	return nil
end

BaseStates.Chase = {
	OnEnter = function(agent: any)
		if agent.Humanoid then
			agent.Humanoid.WalkSpeed = agent.Config.ChaseSpeed
		end
		agent:PlayLocomotion("Walk")
		agent.StateData.repathTimer = agent.Config.PathRecomputeInterval -- recomputa ja no 1o update
		agent.StateData.loseTimer = 0
		agent.StateData.senseTimer = 0
		agent.StateData.visible = true
	end,

	OnUpdate = function(agent: any, dt: number)
		local target = agent.Blackboard.Target :: Player?
		local hrp = targetRoot(target)
		if not hrp then
			agent.Blackboard.Target = nil
			agent:SetState("Patrol")
			return
		end

		local dist = agent:DistanceTo(hrp.Position)

		-- Reavalia a visibilidade em intervalos (SenseInterval) para nao raycastar todo frame.
		agent.StateData.senseTimer += dt
		if agent.StateData.senseTimer >= agent.Config.SenseInterval then
			agent.StateData.senseTimer = 0
			agent.StateData.visible = dist <= agent.Config.DetectionRadius
				and (not agent.Config.RequireLineOfSight or agent:HasLineOfSight(target))
		end

		if agent.StateData.visible then
			agent.StateData.loseTimer = 0
		else
			agent.StateData.loseTimer += dt
			if agent.StateData.loseTimer >= agent.Config.LoseTargetTime then
				agent.Blackboard.Target = nil
				agent:SetState("Patrol")
				return
			end
		end

		-- Alcancou o player: dispara o gancho de contato (no-op por padrao).
		if dist <= agent.Config.ReachDistance and agent.OnReachPlayer then
			agent.OnReachPlayer(agent, target)
		end

		-- Recomputa o caminho (PathfindingService puro) ate a posicao atual do player.
		agent.StateData.repathTimer += dt
		if agent.StateData.repathTimer >= agent.Config.PathRecomputeInterval then
			agent.StateData.repathTimer = 0
			agent:MoveToPosition(hrp.Position)
		end
	end,
}

--== Hunt =====================================================================================

-- Perseguicao IMPLACAVEL: corre atras do alvo (blackboard.Target) sem nunca desistir, ignorando
-- linha de visao/raio de deteccao. Se o alvo sai/morre, re-adquire o player vivo mais proximo.
-- Toca a animacao de corrida ("Run") na velocidade de perseguicao. Usado quando o NPC vira um
-- cacador ativo (ex.: Secretary apos a falha do puzzle do monitor).
BaseStates.Hunt = {
	OnEnter = function(agent: any)
		if agent.Humanoid then
			agent.Humanoid.WalkSpeed = agent.Config.ChaseSpeed
		end
		agent:PlayLocomotion("Run")
		agent.StateData.repathTimer = agent.Config.PathRecomputeInterval -- repath ja no 1o update
	end,

	OnUpdate = function(agent: any, dt: number)
		local hrp = targetRoot(agent.Blackboard.Target)
		if not hrp then
			-- Alvo saiu/morreu: re-adquire o player vivo mais proximo (raio ilimitado).
			local nearest = agent:GetNearestPlayer(math.huge)
			if nearest then
				agent.Blackboard.Target = nearest
				hrp = targetRoot(nearest)
			end
			if not hrp then
				-- Ninguem para cacar no momento; aguarda (segue tocando a corrida parado).
				return
			end
		end

		agent.StateData.repathTimer += dt
		if agent.StateData.repathTimer >= agent.Config.PathRecomputeInterval then
			agent.StateData.repathTimer = 0
			agent:MoveToPosition(hrp.Position)
		end

		-- Alcancou o player: dispara o gancho de contato (no-op por padrao).
		if agent:DistanceTo(hrp.Position) <= agent.Config.ReachDistance and agent.OnReachPlayer then
			agent.OnReachPlayer(agent, agent.Blackboard.Target)
		end
	end,
}

return BaseStates
