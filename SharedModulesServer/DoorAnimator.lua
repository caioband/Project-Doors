--!strict
-- DoorAnimator
-- Anima abrir/fechar uma porta no padrao do modelo de exemplo Workspace.DoorNormal.Door.
-- A maçaneta (Knob) gira usando molas (SpringEffects) e em seguida a porta gira na
-- dobradica via TweenService, alternando entre aberta e fechada (toggle).
--
-- Estrutura esperada do modelo "Door":
--   Door (Model, PrimaryPart = Hinge)
--   |- Hinge (Part, Anchored)   -> Motor6D (Part0 = Hinge, Part1 = painel "Door")  -- raiz/dobradica
--   |- Door  (MeshPart, painel) -> Motor6D (Part0 = Door,  Part1 = Plate)
--   |- Plate (MeshPart)         -> Motor6D (Part0 = Plate, Part1 = Knob)           -- giro da maçaneta
--   |- Knob  (MeshPart)         -> ProximityPrompt (atributo "IsDoor")
--
-- A Hinge e a raiz ancorada da montagem: girar a Hinge (em torno do pivot dela) leva
-- o resto da porta junto. A maçaneta gira a parte pelo seu proprio Motor6D.
-- A animacao roda no servidor e e replicada para os clientes.
--
-- Os comandos sao SERIALIZADOS por porta: enquanto uma animacao roda, a porta fica
-- "busy" e novos comandos sao rejeitados. O estado aberta/fechada NAO e guardado em
-- variavel: e derivado da geometria — a porta esta fechada quando a Hinge esta na
-- rotacao original gravada, e aberta caso contrario. Assim nunca dessincroniza da pose
-- visual (sobrevive ate a resets externos que reposicionem a porta).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local spr = require(ReplicatedStorage.Shared.SharedModules.SpringEffects)

local DoorAnimator = {}

-- Config ------------------------------------------------------------------
-- Maçaneta: giro rapido e firme.
local KNOB_TURN_ANGLE = math.rad(75) -- quanto a maçaneta gira ao acionar
local KNOB_DAMPING = 1
local KNOB_FREQUENCY = 6

-- Porta: abertura via TweenService (a Hinge gira em torno do pivot dela).
local DOOR_OPEN_ANGLE = math.rad(90) -- quanto a porta abre por padrao (sinal define o lado)
local DOOR_TWEEN_INFO = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Atributo (em GRAUS) no Knob: offset somado ao DOOR_OPEN_ANGLE desta porta.
-- Ex.: 0 (ou ausente) abre o default; 15 abre 15° a mais; -15 a menos.
local OPEN_ANGLE_OFFSET_ATTRIBUTE = "OpenAngleOffset"

-- Atributo (boolean) no Knob: inverte o lado de abertura desta porta.
-- Aplicado depois do offset, entao o angulo final apenas troca de sinal.
local MIRROR_ATTRIBUTE = "Mirror"

-- Tempo (s) entre o giro da maçaneta e a porta comecar a abrir.
local OPEN_DELAY = 0.22

-- Janela (s) em que a porta continua "busy" apos reativar o prompt. Se a tecla ficou
-- segurada, o ProximityPrompt dispara um Triggered "fantasma" na reativacao; manter o
-- busy por esse instante faz esse acionamento ser rejeitado. Curto o bastante para nao
-- engolir um novo acionamento real (que exige soltar e apertar de novo).
local REENABLE_GRACE = 0.15

-- Tolerancias para considerar a Hinge no CFrame original (porta fechada), comparando
-- posicao e rotacao do CFrame puro. O tween assenta exatamente no alvo, entao bastam
-- margens pequenas contra ruido float.
local CLOSED_POS_EPSILON = 0.05 -- studs
local CLOSED_ANGLE_EPSILON = math.rad(1)
--------------------------------------------------------------------------

-- Pose original (porta fechada) gravada por Instance: C0 de descanso da maçaneta e o
-- CFrame puro da Hinge (base da animacao e criterio aberto/fechado).
--
-- IMPORTANTE: tabelas FORTES (sem __mode = "k"). Com chave fraca, o GC do Roblox pode
-- coletar o wrapper Lua da Instance mesmo com ela viva no jogo, evictando a entrada; no
-- acesso seguinte a pose ATUAL (aberta) era recapturada como "original", fazendo a porta
-- ler-se fechada estando aberta e ACUMULAR abertura (ex.: -90 -> 180). A limpeza para
-- evitar vazamento e feita no Destroying de cada Instance, dentro dos getters.
local originalC0: { [Motor6D]: CFrame } = {}
local originalCFrame: { [BasePart]: CFrame } = {}

-- Porta com animacao em andamento: enquanto true, novos comandos sao rejeitados.
-- Serializa os toggles para o estado nunca dessincronizar da pose visual. Tabela FORTE
-- (a entrada e zerada com nil ao terminar, entao se auto-limpa) para nao sofrer a mesma
-- eviction por GC que afetaria a serializacao no meio da animacao.
local busy: { [Model]: boolean } = {}

local function getOriginalC0(motor: Motor6D): CFrame
	local c0 = originalC0[motor]
	if not c0 then
		c0 = motor.C0
		originalC0[motor] = c0
		motor.Destroying:Once(function()
			originalC0[motor] = nil
		end)
	end
	return c0
end

-- Calcula o C0 que rotaciona a Part1 do motor em torno do PIVOT da propria part
-- (part:GetPivot()), e nao em torno da junta/Root. 'angles' e aplicado no espaco do pivot.
--
-- A junta segue:  Part1 = Part0 * C0 * C1:Inverse()
-- Rotacionar a part em torno do seu pivot:  Part1' = Part1 * (PivotOffset * angles * PivotOffset⁻¹)
-- Resolvendo para o novo C0 (independente da posicao no mundo):
--   C0' = C0base * C1⁻¹ * (PivotOffset * angles * PivotOffset⁻¹) * C1
local function pivotC0(motor: Motor6D, part: BasePart, angles: CFrame): CFrame
	local pivotOffset = part.PivotOffset
	local delta = pivotOffset * angles * pivotOffset:Inverse()
	local c1 = motor.C1
	return getOriginalC0(motor) * c1:Inverse() * delta * c1
end

local function getOriginalCFrame(part: BasePart): CFrame
	local c = originalCFrame[part]
	if not c then
		c = part.CFrame
		originalCFrame[part] = c
		part.Destroying:Once(function()
			originalCFrame[part] = nil
		end)
	end
	return c
end

-- Pivot original = CFrame original * PivotOffset (mesma fonte que o criterio aberto/fechado,
-- garantindo que a base do tween e o isClosed nunca divirjam).
local function getOriginalPivot(part: BasePart): CFrame
	return getOriginalCFrame(part) * part.PivotOffset
end

-- True se a Hinge esta (aprox.) no CFrame original gravado, ou seja, a porta esta
-- fechada. A decisao de abrir/fechar vem daqui: fechada -> abre, aberta -> fecha.
-- Compara o CFrame puro do Hinge (posicao + rotacao), nao so a rotacao.
local function isClosed(hingePart: BasePart): boolean
	local rel = getOriginalCFrame(hingePart):ToObjectSpace(hingePart.CFrame)
	local _, angle = rel:ToAxisAngle()
	return rel.Position.Magnitude <= CLOSED_POS_EPSILON and angle <= CLOSED_ANGLE_EPSILON
end

-- Angulo de abertura desta porta = default + offset do atributo do Knob (em graus),
-- com o sinal invertido quando o atributo Mirror estiver ligado.
-- Atributos ausentes/invalidos = sem offset e sem espelhamento (apenas DOOR_OPEN_ANGLE).
local function getOpenAngle(knob: BasePart): number
	local angle = DOOR_OPEN_ANGLE
	local offset = knob:GetAttribute(OPEN_ANGLE_OFFSET_ATTRIBUTE)
	if typeof(offset) == "number" then
		angle += math.rad(offset)
	end
	if knob:GetAttribute(MIRROR_ATTRIBUTE) == true then
		angle = -angle
	end
	return angle
end

-- Localiza o Motor6D que gira a maçaneta (Part1 == Knob).
local function findKnobMotor(model: Model, knob: BasePart): Motor6D?
	for _, d in model:GetDescendants() do
		if d:IsA("Motor6D") and d.Part1 == knob then
			return d
		end
	end
	return nil
end

-- Sincroniza o PathfindingModifier da porta com o estado dela. O modifier fica DENTRO da MeshPart
-- do painel (o filho BasePart chamado "Door") do modelo da porta.
--   * FECHADA -> PassThrough = true  : o PathfindingService ATRAVESSA a porta fechada, entao o
--     caminho ate um alvo numa sala com a porta fechada computa (o NPC vai ate a porta e a abre)
--     em vez de dar NoPath.
--   * ABERTA  -> PassThrough = false : a porta ja saiu do vao; volta a usar a colisao real.
-- No-op se a porta nao tiver o painel/modifier.
local function setDoorPassThrough(doorModel: Model, open: boolean)
	local panel = doorModel:FindFirstChild("Door")
	if not (panel and panel:IsA("BasePart")) then
		return
	end
	local modifier = panel:FindFirstChildOfClass("PathfindingModifier")
	if modifier then
		modifier.PassThrough = not open
	end
end

-- Define o estado da porta (open = true abre, false fecha) a partir do Knob (maçaneta).
-- Retorna true se a animacao iniciou; false se ja estava nesse estado, ocupada ou invalida.
function DoorAnimator.SetOpen(knob: BasePart, open: boolean): boolean
	local model = knob.Parent
	if not (model and model:IsA("Model")) then
		return false
	end
	local doorModel = model :: Model

	-- Animacao em andamento: rejeita comandos sobrepostos. Serializar os toggles impede
	-- que dois acionamentos em fila (que escapam antes do prompt desativar, por causa dos
	-- sinais deferred do prompt) disputem e movam a porta de forma inconsistente.
	if busy[doorModel] then
		return false
	end

	local hinge = doorModel.PrimaryPart
	local knobMotor = findKnobMotor(doorModel, knob)
	if not (hinge and knobMotor) then
		warn(`[DoorAnimator] Hinge (PrimaryPart) ou Motor6D do Knob nao encontrado em {doorModel:GetFullName()}`)
		return false
	end
	local hingePart = hinge :: BasePart
	local knobM = knobMotor :: Motor6D

	-- Garante o pivot fechado em cache antes de qualquer rotacao.
	local basePivot = getOriginalPivot(hingePart)

	-- Ja esta no estado desejado (medido pela geometria): nada a fazer.
	--if isClosed(hingePart) ~= open then
	--	return false
	--end

	-- Comando aceito: trava a porta para serializar a animacao.
	busy[doorModel] = true

	-- Mantem o PathfindingModifier em sincronia com o estado desejado: aberta -> PassThrough=false,
	-- fechada -> PassThrough=true. Feito ja no inicio (pelo alvo 'open'), nao no fim da animacao.
	setDoorPassThrough(doorModel, open)

	-- Desativa a interacao durante toda a animacao (o Animator e o dono do prompt).
	local prompt = doorModel:FindFirstChildWhichIsA("ProximityPrompt", true)
	if prompt then
		prompt.Enabled = false
	end

	-- 1) Gira a maçaneta em torno do pivot dela (eixo Z = giro da alavanca).
	spr.target(knobM, KNOB_DAMPING, KNOB_FREQUENCY, {
		C0 = pivotC0(knobM, knob, CFrame.Angles(0, 0, KNOB_TURN_ANGLE)),
	})

	-- 2) Apos um instante, gira a Hinge (a porta inteira vai junto) para a pose aberta
	--    ou de volta a fechada; ao terminar, devolve a maçaneta e libera a porta.
	--task.delay(OPEN_DELAY, function()
		local hingeTarget = if open
			then basePivot * CFrame.Angles(0, getOpenAngle(knob), 0)
			else basePivot

		-- Pivot nao e tweenavel: anima o CFrame que coloca o pivot da Hinge no alvo.
		-- (GetPivot() == CFrame * PivotOffset, entao CFrame = alvo * PivotOffset:Inverse().)
		local hingeCFrame = hingeTarget * hingePart.PivotOffset:Inverse()
		local tween = TweenService:Create(hingePart, DOOR_TWEEN_INFO, { CFrame = hingeCFrame })

		-- Ao terminar o giro da porta, devolve a maçaneta; quando ela assenta, reativa a
		-- interacao e libera a porta. O busy so cai apos REENABLE_GRACE para rejeitar o
		-- Triggered "fantasma" caso a tecla tenha ficado segurada na reativacao.
		tween.Completed:Once(function()
			spr.target(knobM, KNOB_DAMPING, KNOB_FREQUENCY, { C0 = getOriginalC0(knobM) })
			spr.completed(knobM, function()
				if prompt then
					prompt.Enabled = true
				end
				task.delay(REENABLE_GRACE, function()
					busy[doorModel] = nil
				end)
			end)
		end)
		tween:Play()
	--end)

	return true
end

-- True se a porta (pelo Knob) esta aberta (Hinge fora da pose original). False se fechada ou
-- se a estrutura for invalida. Util para abrir sob demanda so quando fechada (ex.: NPC).
function DoorAnimator.IsOpen(knob: BasePart): boolean
	local model = knob.Parent
	if not (model and model:IsA("Model")) then
		return false
	end
	local hinge = (model :: Model).PrimaryPart
	if not hinge then
		return false
	end
	return not isClosed(hinge :: BasePart)
end

-- Abre a porta.
function DoorAnimator.Open(knob: BasePart): boolean
	return DoorAnimator.SetOpen(knob, true)
end

-- Fecha a porta.
function DoorAnimator.Close(knob: BasePart): boolean
	return DoorAnimator.SetOpen(knob, false)
end

-- Alterna entre aberta e fechada, decidindo pela rotacao atual da Hinge:
-- na rotacao original (fechada) -> abre; em qualquer outra (aberta) -> fecha.
function DoorAnimator.Toggle(knob: BasePart): boolean
	local model = knob.Parent
	if not (model and model:IsA("Model")) then
		return false
	end
	local hinge = (model :: Model).PrimaryPart
	if not hinge then
		return false
	end

	return DoorAnimator.SetOpen(knob, isClosed(hinge :: BasePart))
end

-- Grava a rotacao inicial (fechada) da Hinge desta porta para servir de referencia ao
-- decidir abrir/fechar. Idempotente; chame uma vez no setup de cada porta (com a porta
-- na pose fechada). Sem isso, a referencia e capturada de forma preguicosa no 1o toggle.
function DoorAnimator.Register(knob: BasePart)
	local model = knob.Parent
	if not (model and model:IsA("Model")) then
		return
	end
	local hinge = (model :: Model).PrimaryPart
	if hinge then
		-- Cache unico: getOriginalPivot deriva deste mesmo CFrame.
		getOriginalCFrame(hinge :: BasePart)
		-- Estado inicial do PathfindingModifier conforme a pose atual (registrada fechada ->
		-- PassThrough=true, para o pathfinding ja atravessar portas fechadas desde a carga do mapa).
		setDoorPassThrough(model :: Model, DoorAnimator.IsOpen(knob))
	end
end

return DoorAnimator
