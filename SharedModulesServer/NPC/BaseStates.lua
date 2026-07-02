--!strict
-- BaseStates
-- Comportamentos BASE reutilizaveis por todos os NPCs, como estados de uma state machine.
-- Cada estado e uma tabela { OnEnter?, OnUpdate?, OnExit? } que recebe o NPCAgent (self) e le
-- os thresholds de agent.Config. Um NPC especifico (NPCBehaviors/<Nome>.lua) pode sobrescrever
-- qualquer um destes ou adicionar novos.
--
--   * Idle   - parado (anim idle) por um tempo; ao expirar vai patrulhar. Detecta player -> Hunt.
--   * Patrol - anda entre os AINodes (NavGraph). Ao chegar, volta a Idle (pausa natural entre
--              nodes). Detecta player -> Hunt.
--   * Hunt   - persegue o player (blackboard.Target) na velocidade/anim de corrida ("Run"),
--              recomputando o caminho. Fica fora da visao por LoseTargetTime s -> volta a Patrol.
--              Ao alcancar, chama o gancho OnReachPlayer (stub; NPCs so se movem por enquanto).
--              E a UNICA rotina de perseguicao (Idle/Patrol detectam -> Hunt; o hunter spawnado
--              tambem comeca em Hunt), para o comportamento e a animacao serem sempre consistentes.

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
			agent:SetState("Hunt")
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
			agent:SetState("Hunt")
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

--== Hunt =====================================================================================

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

-- Perseguicao: corre atras do alvo (blackboard.Target) na velocidade de perseguicao, tocando a
-- animacao "Run". A Secretary comeca aqui (apos a falha do puzzle). Ela DESISTE e vai patrulhar os
-- AINodes quando o alvo fica FORA DA VISAO (fora do DetectionRadius OU sem linha de visao) por
-- LoseTargetTime segundos. O contador so vale depois de ter visto o alvo ao menos uma vez
-- (hasSeen), para nao desistir durante a aproximacao inicial (caso spawne longe do alvo).
BaseStates.Hunt = {
	OnEnter = function(agent: any)
		if agent.Humanoid then
			agent.Humanoid.WalkSpeed = agent.Config.ChaseSpeed
		end
		agent:PlayLocomotion("Run")
		agent.StateData.repathTimer = agent.Config.PathRecomputeInterval -- repath ja no 1o update
		agent.StateData.senseTimer = 0
		agent.StateData.loseTimer = 0
		agent.StateData.hasSeen = false
		agent.StateData.visible = false
	end,

	OnUpdate = function(agent: any, dt: number)
		local target = agent.Blackboard.Target
		local hrp = targetRoot(target)
		if not hrp then
			-- Alvo saiu/morreu: vai patrulhar.
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
			agent.StateData.hasSeen = true
			agent.StateData.loseTimer = 0
		elseif agent.StateData.hasSeen then
			-- Ja viu o alvo e agora esta fora da visao: conta para desistir e ir patrulhar.
			agent.StateData.loseTimer += dt
			if agent.StateData.loseTimer >= agent.Config.LoseTargetTime then
				agent.Blackboard.Target = nil
				agent:SetState("Patrol")
				return
			end
		end

		-- Persegue a posicao atual do alvo (recomputa o caminho periodicamente).
		agent.StateData.repathTimer += dt
		if agent.StateData.repathTimer >= agent.Config.PathRecomputeInterval then
			agent.StateData.repathTimer = 0
			agent:MoveToPosition(hrp.Position)
		end

		-- Alcancou o player: dispara o gancho de contato (no-op por padrao).
		if dist <= agent.Config.ReachDistance and agent.OnReachPlayer then
			agent.OnReachPlayer(agent, target)
		end
	end,
}

return BaseStates
