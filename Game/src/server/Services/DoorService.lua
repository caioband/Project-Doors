--!strict
-- DoorService
-- Responsavel por:
--   * Escutar os descendentes adicionados a Workspace (e os que ja existem ao iniciar).
--   * Quando o descendente e um ProximityPrompt com o atributo "IsDoor" cujo parent e um
--     Knob, conectar o acionamento do prompt ao toggle da porta.
--   * Ao acionar, se o Knob NAO estiver com o atributo "Locked", anima a maçaneta e
--     alterna a porta entre aberta e fechada (via DoorAnimator).
--   * Reportar o BARULHO da porta ao NoiseService (o BusinessMan caca por som).
--
-- So o acionamento por PROMPT (um player usando a porta) faz barulho. O :OpenDoor programatico e
-- SILENCIOSO de proposito: hoje quem o usa e o proprio NPC abrindo portas no caminho (ver
-- NPCAgent:_scanDoors), e reportar ali o faria correr atras do barulho que ele mesmo produziu.

local Workspace = game:GetService("Workspace")
local ServerScriptService = game:GetService("ServerScriptService")

local DoorAnimator = require(ServerScriptService.Server.SharedModules.DoorAnimator)

local DoorService = {}

-- ProximityPrompts ja conectados, para nao duplicar conexoes.
local connectedPrompts: { [ProximityPrompt]: boolean } = setmetatable({}, { __mode = "k" }) :: any

-- A porta esta trancada quando o Knob tem o atributo "Locked" verdadeiro.
local function isLocked(knob: Instance): boolean
	return knob:GetAttribute("Locked") == true
end

-- NoiseService, resolvido no :Start (os prompts sao conectados por funcoes locais, sem self).
local NoiseService: any = nil

-- Reporta o barulho de uma porta sendo usada por um player, na posicao do Knob.
local function reportDoorNoise(knob: BasePart, player: Player?)
	if not NoiseService then
		return
	end
	NoiseService:Report(knob.Position, NoiseService.Config.DoorRadius, "Door", player)
end

-- Conecta um ProximityPrompt de porta ao fluxo de abertura.
local function setupPrompt(prompt: ProximityPrompt)
	if connectedPrompts[prompt] then
		return
	end

	-- So nos interessa o prompt marcado como porta.
	if prompt:GetAttribute("IsDoor") ~= true then
		return
	end

	-- O parent precisa ser um Knob (BasePart chamada "Knob").
	local knob = prompt.Parent
	if not (knob and knob:IsA("BasePart") and knob.Name == "Knob") then
		return
	end
	local knobPart = knob :: BasePart

	connectedPrompts[prompt] = true

	-- Grava a rotacao inicial (fechada) da porta agora, no setup, para servir de
	-- referencia ao DoorAnimator decidir abrir/fechar.
	DoorAnimator.Register(knobPart)

	prompt.TriggerEnded:Connect(function(player)
		-- Trancada: ignora o acionamento.
		if isLocked(knobPart) then
			return
		end
		-- Abrir OU fechar faz barulho (a porta e a dobradica soam nos dois sentidos).
		reportDoorNoise(knobPart, player)
		-- Alterna entre abrir e fechar a cada acionamento. O DoorAnimator e o dono do
		-- prompt: ele desativa durante a animacao e reativa ao terminar, e rejeita
		-- acionamentos sobrepostos (busy) — por isso nao mexemos no Enabled aqui.
		DoorAnimator.Toggle(knobPart)
	end)
end

local function onDescendantAdded(descendant: Instance)
	if descendant:IsA("ProximityPrompt") then
		setupPrompt(descendant)
	end
end

-- Resolve o Knob (BasePart "Knob") a partir de um Knob direto ou de um Model de porta.
local function resolveKnob(door: Instance): BasePart?
	if door:IsA("BasePart") and door.Name == "Knob" then
		return door
	end
	if door:IsA("Model") then
		local knob = door:FindFirstChild("Knob")
		if knob and knob:IsA("BasePart") then
			return knob
		end
	end
	return nil
end

-- Abre uma porta programaticamente (aceita o Knob ou o Model da porta). Abre APENAS se estiver
-- fechada (idempotente: no-op se ja aberta ou em animacao). Diferente do acionamento por prompt,
-- NAO checa o atributo "Locked" — e uma abertura forcada usada por sistemas do jogo (ex.: a
-- Secretary abrindo portas no caminho ao cacar). Retorna true se iniciou a animacao de abertura.
function DoorService:OpenDoor(door: Instance): boolean
	local knob = resolveKnob(door)
	if not knob then
		return false
	end
	if DoorAnimator.IsOpen(knob) then
		return false
	end
	return DoorAnimator.Open(knob)
end

-- True se a porta (aceita o Knob ou o Model) esta aberta; false se fechada ou invalida. Usado por
-- sistemas do jogo para decidir agir so quando fechada (ex.: o NPC escolhe a porta FECHADA no
-- caminho para ir abrir quando o pathfinding da NoPath). Ver NPCAgent:_pickBlockingDoor.
function DoorService:IsOpen(door: Instance): boolean
	local knob = resolveKnob(door)
	if not knob then
		return false
	end
	return DoorAnimator.IsOpen(knob)
end

function DoorService:Init() end

function DoorService:Start()
	NoiseService = self.GetService and self.GetService("NoiseService")

	-- Conecta os prompts ja presentes na Workspace.
	for _, descendant in Workspace:GetDescendants() do
		onDescendantAdded(descendant)
	end

	-- E escuta os que forem adicionados depois.
	Workspace.DescendantAdded:Connect(onDescendantAdded)
end

return DoorService
