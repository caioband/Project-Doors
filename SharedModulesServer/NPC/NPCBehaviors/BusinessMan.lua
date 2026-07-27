--!strict
-- NPCBehaviors/BusinessMan
-- Logica UNICA do NPC "BusinessMan" (mapa Office). Resolvido pelo NPCService a partir do nome do
-- Model em AIModels (Model.Name == "BusinessMan").
--
-- Ele e CEGO: caca EXCLUSIVAMENTE por barulho (NoiseService, via NPCAgent:Hear). DetectionRadius = 0
-- garante que o :Sense nunca ache ninguem, e nenhum estado daqui o chama.
--
-- SPAWN: nao esta em cena desde o inicio. O MapBehaviors/Office o esconde no OnLoad e, com 99% de
-- chance, o spawna num instante sorteado entre 60 e 90 s de rodada, sempre num AINode fora do campo
-- de visao dos players (NPCService:SpawnHidden). Ele entra pelo StartState abaixo — ou seja,
-- vagando, NAO cacando: quem o coloca em Hunt e o barulho que voce fizer.
--
-- O ponto central do design: ele persegue a POSICAO DO RUIDO, nunca o player. Nao existe tracking —
-- se voce parar de andar, agachar ou so ficar quieto, ele vai ate onde ouviu o ultimo barulho,
-- procura por SearchTime segundos e desiste. Cada passo seu re-atualiza o destino dele.
--
-- Fluxo dos estados (todos ouvem; nenhum enxerga):
--
--   Idle  <-->  Patrol            barulho longe -> Investigate | barulho perto -> Hunt
--                 |
--                 v
--            Investigate          anda (Walk) ate o ponto, procura, e volta a Patrol.
--                 |               NAO liga SetHunting: sem HuntAudio nem heartbeat no client —
--                 v               a tensao fica reservada para o Hunt.
--               Hunt              corre (Run) ate o ponto. Ruido novo reescreve o ponto e zera o
--                                 silencio; LoseNoiseTime sem barulho -> Investigate -> Patrol.
--
-- O contato e o gancho OnReachPlayer do NPCAgent, que continua sendo um stub (ele so encosta).

local BusinessMan = {}

BusinessMan.Config = {
	-- CEGO. Estes dois existem so para documentar/garantir: nenhum estado daqui chama o :Sense.
	DetectionRadius = 0,
	RequireLineOfSight = false,

	-- Patrulha devagar (procurando), persegue rapido.
	WalkSpeed = 9,
	ChaseSpeed = 20,

	-- Audicao: 1 = ouve exatamente ate onde o raio do ruido alcanca. Suba para deixa-lo mais
	-- perigoso sem mexer nas fontes de barulho.
	HearingMultiplier = 1,
	HearInterval = 0.15,

	-- Barulho MAIS PERTO que isto ja assusta: vai direto para Hunt (correndo) em vez de investigar.
	AlertRadius = 18,
	-- Segundos parado procurando no ponto do ruido antes de voltar a patrulhar.
	SearchTime = 4,
	-- Segundos SEM nenhum barulho novo durante o Hunt antes de desistir da perseguicao.
	LoseNoiseTime = 6,
	-- Quanto (studs) o destino precisa ter andado para valer um novo pathfinding. Existe porque
	-- CADA :MoveToPosition CANCELA o movimento em andamento (incrementa o _moveToken): recalcular a
	-- cada passo ouvido faz o NPC reiniciar o path sem nunca chegar ao Humanoid:MoveTo — ele entra
	-- em Hunt e fica PARADO. Com o delta, so recalcula quando o alvo realmente mudou de lugar.
	RepathMinDelta = 6,

	-- IDs das animacoes de locomocao. O Model usa uma RIG CUSTOMIZADA (Humanoid com RigType R6, mas
	-- sem os membros R6 padrao: o corpo e um unico MeshPart com bones, autorado em
	-- ServerStorage.RBX_ANIMSAVES.BusinessMan) — estas animacoes so servem para ESTE rig.
	-- O NPCAgent as toca por nome: Idle no Idle, Walk no Patrol/Investigate, Run no Hunt.
	Animations = {
		Idle = "rbxassetid://78844601233035",
		Walk = "rbxassetid://102744309623003",
		Run = "rbxassetid://96128859160949",
	},
}

BusinessMan.StartState = "Idle"


-- Guarda o barulho ouvido no blackboard. O Target e setado so para o gancho OnReachPlayer e para a
-- telemetria — o MOVIMENTO usa NoisePos, nunca a posicao atual do player.
local function rememberNoise(agent: any, noise: any)
	agent.Blackboard.NoisePos = noise.Position
	agent.Blackboard.Target = noise.Player
end

-- Para onde ir ao ouvir algo: perto o bastante assusta (Hunt), longe so desperta a curiosidade.
local function reactionTo(agent: any, noise: any): string
	if agent:DistanceTo(noise.Position) <= agent.Config.AlertRadius then
		return "Hunt"
	end
	return "Investigate"
end

-- Manda o NPC ate 'destination', mas SO quando vale a pena reemitir a ordem: se o destino mal se
-- moveu e ele ainda esta a caminho, reemitir cancelaria o movimento atual (ver RepathMinDelta) e ele
-- ficaria parado tremendo entre recalculos. Reemite quando o alvo andou o bastante OU quando o
-- movimento anterior ja acabou (chegou/falhou).
local function moveTowards(agent: any, destination: Vector3)
	local last = agent.StateData.lastDest
	local movingStill = agent.MoveStatus == "moving"
	if last and movingStill and (last - destination).Magnitude <= agent.Config.RepathMinDelta then
		return
	end
	agent.StateData.lastDest = destination
	agent:MoveToPosition(destination)
end


BusinessMan.States = {
	--== Idle ==================================================================================
	-- Igual ao BaseStates.Idle, trocando :Sense (visao) por :Hear (audicao).
	Idle = {
		OnEnter = function(agent: any)
			agent:Stop()
			agent:PlayLocomotion("Idle")
			agent.StateData.timer = 0
			agent.StateData.wait = agent.Config.IdleTimeMin
				+ math.random() * math.max(agent.Config.IdleTimeMax - agent.Config.IdleTimeMin, 0)
		end,

		OnUpdate = function(agent: any, dt: number)
			local noise = agent:Hear(dt)
			if noise then
				rememberNoise(agent, noise)
				agent:SetState(reactionTo(agent, noise))
				return
			end

			agent.StateData.timer += dt
			if agent.StateData.timer >= agent.StateData.wait then
				agent:SetState("Patrol")
			end
		end,
	},

	--== Patrol ================================================================================
	-- Igual ao BaseStates.Patrol, trocando :Sense por :Hear.
	Patrol = {
		OnEnter = function(agent: any)
			if agent.Humanoid then
				agent.Humanoid.WalkSpeed = agent.Config.WalkSpeed
			end
			agent:PlayLocomotion("Walk")
			agent.StateData.needTarget = true
		end,

		OnUpdate = function(agent: any, dt: number)
			local noise = agent:Hear(dt)
			if noise then
				rememberNoise(agent, noise)
				agent:SetState(reactionTo(agent, noise))
				return
			end

			if agent.StateData.needTarget then
				agent.StateData.needTarget = false
				local node = agent.NavGraph
					and agent.NavGraph:GetRandomNodeAwayFrom(agent.RootPart.Position, agent.Config.PatrolMinNodeDist)
				if node then
					agent:MoveToPosition(node.Position)
				else
					agent:SetState("Idle")
				end
				return
			end

			if agent.MoveStatus == "reached" then
				agent:SetState("Idle")
			elseif agent.MoveStatus == "failed" then
				agent.StateData.needTarget = true
			end
		end,
	},

	--== Investigate ===========================================================================
	-- Vai ANDANDO ate onde ouviu e vasculha. Nao e caca ainda: SetHunting fica desligado, entao
	-- nem o HuntAudio toca nem o heartbeat/tremor do HuntSensesController liga no client.
	Investigate = {
		OnEnter = function(agent: any)
			if agent.Humanoid then
				agent.Humanoid.WalkSpeed = agent.Config.WalkSpeed
			end
			agent:PlayLocomotion("Walk")
			agent.StateData.searchTimer = 0
			agent.StateData.arrived = false

			local pos = agent.Blackboard.NoisePos
			if not pos then
				agent:SetState("Patrol")
				return
			end
			moveTowards(agent, pos)
		end,

		OnUpdate = function(agent: any, dt: number)
			local noise = agent:Hear(dt)
			if noise then
				rememberNoise(agent, noise)
				if agent:DistanceTo(noise.Position) <= agent.Config.AlertRadius then
					agent:SetState("Hunt")
					return
				end
				-- Barulho novo mas ainda longe: redireciona e recomeca a aproximacao.
				agent.StateData.arrived = false
				agent.StateData.searchTimer = 0
				agent:PlayLocomotion("Walk")
				moveTowards(agent, noise.Position)
				return
			end

			-- Ainda a caminho. "failed" tambem conta como chegada: sem rota ate o ponto, vasculha
			-- de onde parou em vez de ficar tentando para sempre.
			if not agent.StateData.arrived then
				if agent.MoveStatus == "reached" or agent.MoveStatus == "failed" then
					agent.StateData.arrived = true
					agent:Stop()
					agent:PlayLocomotion("Idle")
				end
				return
			end

			agent.StateData.searchTimer += dt
			if agent.StateData.searchTimer >= agent.Config.SearchTime then
				-- Nao achou nada: esquece o rastro e volta a rotina.
				agent.Blackboard.NoisePos = nil
				agent.Blackboard.Target = nil
				agent:SetState("Patrol")
			end
		end,
	},

	--== Hunt ==================================================================================
	-- Override do BaseStates.Hunt: corre para a POSICAO DO RUIDO, nao para o player. E o que faz
	-- ficar parado/agachado ser uma forma valida de escapar.
	Hunt = {
		OnEnter = function(agent: any)
			if agent.Humanoid then
				agent.Humanoid.WalkSpeed = agent.Config.ChaseSpeed
			end
			agent:PlayLocomotion("Run")
			-- Liga o modo caca: HuntAudio do modelo + sinal aos clients (heartbeat/respiracao/tremor).
			agent:SetHunting(true)
			agent.StateData.repathTimer = agent.Config.PathRecomputeInterval -- repath ja no 1o update
			agent.StateData.silenceTimer = 0
		end,

		OnExit = function(agent: any)
			agent:SetHunting(false)
		end,

		OnUpdate = function(agent: any, dt: number)
			local noise = agent:Hear(dt)
			if noise then
				rememberNoise(agent, noise)
				agent.StateData.silenceTimer = 0
				-- NAO forcamos repath aqui: correndo chega um passo a cada ~0.3 s, e cada
				-- MoveToPosition cancela o movimento em curso — ele ficaria parado recalculando.
				-- O tick periodico abaixo pega a posicao nova (via moveTowards).
			else
				agent.StateData.silenceTimer += dt
				if agent.StateData.silenceTimer >= agent.Config.LoseNoiseTime then
					-- Silencio prolongado: perde o rastro. Da uma ultima vasculhada no ponto antes
					-- de voltar a patrulhar (o Investigate cuida de desistir de vez).
					agent:SetState("Investigate")
					return
				end
			end

			local pos = agent.Blackboard.NoisePos
			if not pos then
				agent:SetState("Patrol")
				return
			end

			agent.StateData.repathTimer += dt
			if agent.StateData.repathTimer >= agent.Config.PathRecomputeInterval then
				agent.StateData.repathTimer = 0
				moveTowards(agent, pos)
			end

			-- Contato: quem estiver ao alcance leva o gancho (stub por padrao). Como ele e cego, o
			-- alvo do contato e quem ESTIVER perto, nao quem fez o barulho.
			if agent.OnReachPlayer then
				local player = agent:GetNearestPlayer(agent.Config.ReachDistance)
				if player then
					agent.OnReachPlayer(agent, player)
				end
			end

			-- Chegou no ponto e o barulho nao continuou: passa a vasculhar a area.
			if agent.MoveStatus == "reached" and agent:DistanceTo(pos) <= agent.Config.ReachDistance then
				agent:SetState("Investigate")
			end
		end,
	},
}

return BusinessMan
