--!strict

local ContextActionService = game:GetService("ContextActionService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DeviceController = require(ReplicatedStorage.Shared.SharedModules.DeviceController)

local LocalPlayer = Players.LocalPlayer
local Character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()

local ACTION_NAME = "Sprint"

export type SprintConfig = {
	-- Velocidade base do PC (sem sprint).
	WalkSpeed: number,
	-- Velocidade maxima: sprint (PC) ou thumbstick totalmente esticado (mobile/console).
	SprintSpeed: number,
	-- Velocidade minima do modo analogico (thumbstick no minimo).
	AnalogMinSpeed: number,
	-- Curva de resposta separada por plataforma: o thumbstick dinamico do mobile e o
	-- analogico do controle nao tem o mesmo comportamento. Abaixo da Deadzone (0..1) o input
	-- e ignorado; o Exponent (>1) deixa menos sensivel (precisa esticar mais para acelerar).
	MobileDeadzone: number,
	MobileResponseExponent: number,
	ConsoleDeadzone: number,
	ConsoleResponseExponent: number,
}

local DEFAULT_CONFIG: SprintConfig = {
	WalkSpeed = 8,
	SprintSpeed = 20,
	AnalogMinSpeed = 0,
	MobileDeadzone = 0.1,
	MobileResponseExponent = 3.5,
	ConsoleDeadzone = 0.15,
	ConsoleResponseExponent = 3.5,
}

local SprintController = {}

-- Retorna o ControlModule do PlayerModule. O move vector dele tem magnitude analogica
-- (0..1) proporcional ao quanto o thumbstick dinamico do mobile esta esticado.
local function getControls()
	local playerScripts = LocalPlayer:FindFirstChild("PlayerScripts")
	local playerModule = playerScripts and playerScripts:FindFirstChild("PlayerModule")
	if not playerModule then
		return nil
	end

	local ok, controls = pcall(function()
		return require(playerModule):GetControls()
	end)
	return ok and controls or nil
end

function SprintController:Start()
	self.Config = table.clone(DEFAULT_CONFIG)
	self.IsSprinting = false

	local function onCharacterAdded(character: Model)
		local humanoid = character:WaitForChild("Humanoid") :: Humanoid
		self.Humanoid = humanoid

		local HumanoidController = self.GetController("HumanoidController")
		if HumanoidController then
			HumanoidController:SetWalkSpeed(self.Config.WalkSpeed)
		end
	end

	if Character then
		onCharacterAdded(Character)
	end
	LocalPlayer.CharacterAdded:Connect(onCharacterAdded)

	-- PC: o sprint continua sendo a tecla (sem botao de toque e sem botao de controle,
	-- ja que mobile/console usam a velocidade analogica do thumbstick).
	local function onSprintAction(_actionName: string, inputState: Enum.UserInputState)
		if inputState == Enum.UserInputState.Begin then
			self:SetSprinting(true)
		elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
			self:SetSprinting(false)
		end

		return Enum.ContextActionResult.Pass
	end

	ContextActionService:BindAction(ACTION_NAME, onSprintAction, false, Enum.KeyCode.LeftShift)

	-- Console: acompanha a posicao crua do Thumbstick1 (analogico de verdade). Diferente do
	-- mobile, aqui nao dependemos do move vector do ControlModule.
	self.GamepadMoveMagnitude = 0
	UserInputService.InputChanged:Connect(function(input: InputObject)
		if input.KeyCode == Enum.KeyCode.Thumbstick1 then
			local pos = input.Position
			self.GamepadMoveMagnitude = math.min(math.sqrt(pos.X * pos.X + pos.Y * pos.Y), 1)
		end
	end)

	-- Mobile/Console: a WalkSpeed varia conforme o quanto o thumbstick esta esticado.
	RunService.Heartbeat:Connect(function()
		self:_updateAnalogSpeed()
	end)

	print("✓ SprintController initialized")
end

-- Ajusta a WalkSpeed a cada frame conforme o dispositivo atual: no PC respeita o bind
-- (LeftShift); no Mobile/Console usa a magnitude do thumbstick (com curva por plataforma).
function SprintController:_updateAnalogSpeed()
	local humanoid = self.Humanoid
	if not humanoid or humanoid.Health <= 0 then
		return
	end

	-- O modo e escolhido pelo dispositivo atual (ultimo input), nao pelo que esta conectado.
	-- Assim, no PC (teclado/mouse) o sprint continua no LeftShift mesmo com um controle plugado.
	local device = DeviceController:GetDevice()

	if device == "PC" then
		-- Mantem a WalkSpeed coerente com o estado do bind (inclusive ao voltar de um modo
		-- analogico que tenha deixado outro valor). So escreve quando muda.
		local target = self.IsSprinting and self.Config.SprintSpeed or self.Config.WalkSpeed
		if math.abs(humanoid.WalkSpeed - target) > 0.001 then
			humanoid.WalkSpeed = target
		end
		return
	end

	-- A fonte da magnitude e a curva sao escolhidas por plataforma, pois o thumbstick
	-- dinamico (mobile) e o analogico do controle (console) se comportam diferente.
	local raw, deadzone, exponent
	if device == "Mobile" then
		-- Mobile: magnitude via move vector do thumbstick dinamico.
		if not self.Controls then
			self.Controls = getControls()
		end
		if not self.Controls then
			return
		end
		raw = math.clamp(self.Controls:GetMoveVector().Magnitude, 0, 1)
		deadzone = self.Config.MobileDeadzone
		exponent = self.Config.MobileResponseExponent
	else
		-- Console: posicao crua do Thumbstick1.
		raw = math.clamp(self.GamepadMoveMagnitude, 0, 1)
		deadzone = self.Config.ConsoleDeadzone
		exponent = self.Config.ConsoleResponseExponent
	end

	-- Deadzone + curva de resposta: evita que um toque leve no thumbstick ja jogue para a
	-- velocidade maxima. Abaixo da deadzone -> 0; acima, reescala para 0..1 e aplica o expoente.
	local t = 0
	if raw > deadzone then
		t = ((raw - deadzone) / (1 - deadzone)) ^ exponent
	end

	-- t = 0 (parado) -> AnalogMinSpeed; t = 1 (esticado ao maximo) -> SprintSpeed.
	local minSpeed = self.Config.AnalogMinSpeed
	local maxSpeed = self.Config.SprintSpeed
	humanoid.WalkSpeed = minSpeed + (maxSpeed - minSpeed) * t
end

function SprintController:SetSprinting(enabled: boolean)
	if self.IsSprinting == enabled then
		return
	end

	self.IsSprinting = enabled

	local HumanoidController = self.GetController("HumanoidController")
	if not HumanoidController then
		return
	end

	if enabled then
		HumanoidController:SetWalkSpeed(self.Config.SprintSpeed)
	else
		HumanoidController:SetWalkSpeed(self.Config.WalkSpeed)
	end
end

function SprintController:IsRunning(): boolean
	-- No PC reflete o estado do bind; no Mobile/Console reflete a velocidade analogica atual.
	if DeviceController:GetDevice() == "PC" then
		return self.IsSprinting
	end

	local humanoid = self.Humanoid
	return humanoid ~= nil and humanoid.WalkSpeed > self.Config.WalkSpeed + 0.01
end

function SprintController:GetConfig(): SprintConfig
	return self.Config
end

function SprintController:SetConfig(newConfig: { [string]: any })
	for key, value in pairs(newConfig) do
		self.Config[key] = value
	end
end

return SprintController
