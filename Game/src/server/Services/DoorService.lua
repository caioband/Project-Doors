--!strict
-- DoorService
-- Responsavel por:
--   * Escutar os descendentes adicionados a Workspace (e os que ja existem ao iniciar).
--   * Quando o descendente e um ProximityPrompt com o atributo "IsDoor" cujo parent e um
--     Knob, conectar o acionamento do prompt ao toggle da porta.
--   * Ao acionar, se o Knob NAO estiver com o atributo "Locked", anima a maçaneta e
--     alterna a porta entre aberta e fechada (via DoorAnimator).

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

	prompt.TriggerEnded:Connect(function(_player)
		-- Trancada: ignora o acionamento.
		if isLocked(knobPart) then
			return
		end
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

function DoorService:Init() end

function DoorService:Start()
	-- Conecta os prompts ja presentes na Workspace.
	for _, descendant in Workspace:GetDescendants() do
		onDescendantAdded(descendant)
	end

	-- E escuta os que forem adicionados depois.
	Workspace.DescendantAdded:Connect(onDescendantAdded)
end

return DoorService
