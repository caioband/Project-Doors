--!strict

local ContextActionService = game:GetService("ContextActionService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")

local LocalPlayer = Players.LocalPlayer

-- A velocidade analogica (thumbstick) vale quando ha tela de toque ou um controle conectado.
local function usesAnalogMovement(): boolean
	return UserInputService.TouchEnabled or UserInputService.GamepadEnabled
end
local Character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()

local ACTION_NAME = "Sprint"

export type SprintConfig = {
	-- Velocidade base do PC (sem sprint).
	WalkSpeed: number,
	-- Velocidade maxima: sprint (PC) ou thumbstick totalmente esticado (mobile/console).
	SprintSpeed: number,
	-- Velocidade minima do modo analogico (thumbstick no minimo).
	AnalogMinSpeed: number,
	-- Abaixo dessa magnitude (0..1) o thumbstick e ignorado (velocidade minima).
	AnalogDeadzone: number,
	-- Curva de resposta do thumbstick. >1 deixa menos sensivel: e preciso esticar mais
	-- para chegar perto da velocidade maxima (1 = linear).
	AnalogResponseExponent: number,
}

local DEFAULT_CONFIG: SprintConfig = {
	WalkSpeed = 8,
	SprintSpeed = 20,
	AnalogMinSpeed = 0,
	AnalogDeadzone = 0.1,
	AnalogResponseExponent = 2.5,
}

local SprintController = {}

-- Retorna o ControlModule do PlayerModule. O move vector dele tem magnitude analogica
-- (0..1) proporcional ao quanto o thumbstick esta esticado no mobile/console.
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

	-- Mobile/Console: a WalkSpeed varia conforme o quanto o thumbstick esta esticado.
	RunService.Heartbeat:Connect(function()
		self:_updateAnalogSpeed()
	end)

	print("✓ SprintController initialized")
end

-- Define a WalkSpeed proporcional a magnitude do thumbstick (toque/controle).
-- Sem toque nem controle nao faz nada: o sprint continua sendo a tecla (LeftShift).
function SprintController:_updateAnalogSpeed()
	if not usesAnalogMovement() then
		return
	end

	local humanoid = self.Humanoid
	if not humanoid or humanoid.Health <= 0 then
		return
	end

	if not self.Controls then
		self.Controls = getControls()
	end
	local controls = self.Controls
	if not controls then
		return
	end

	local raw = math.clamp(controls:GetMoveVector().Magnitude, 0, 1)

	-- Deadzone + curva de resposta: evita que um toque leve no thumbstick ja jogue para a
	-- velocidade maxima. Abaixo da deadzone -> 0; acima, reescala para 0..1 e aplica o expoente.
	local deadzone = self.Config.AnalogDeadzone
	local t = 0
	if raw > deadzone then
		t = (raw - deadzone) / (1 - deadzone)
		t = t ^ self.Config.AnalogResponseExponent
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
	-- Com tecla reflete o estado do bind; com toque/controle reflete a velocidade analogica atual.
	if not usesAnalogMovement() then
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
