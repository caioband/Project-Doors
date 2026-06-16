--!strict

local ContextActionService = game:GetService("ContextActionService")

local LocalPlayer = game:GetService("Players").LocalPlayer
local Character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()

local ACTION_NAME = "Sprint"

export type SprintConfig = {
	WalkSpeed: number,
	SprintSpeed: number,
	TouchButtonPosition: UDim2,
}

local DEFAULT_CONFIG: SprintConfig = {
	WalkSpeed = 8,
	SprintSpeed = 20,
	TouchButtonPosition = UDim2.fromScale(0.9, 0.8),
}

local SprintController = {}

function SprintController:Start()
	self.Config = table.clone(DEFAULT_CONFIG)
	self.IsSprinting = false

	local function onCharacterAdded(character: Model)
		local humanoid = character:WaitForChild("Humanoid") :: Humanoid
		local HumanoidController = self.GetController("HumanoidController")

		self.Humanoid = humanoid
		print("Character added, applying sprint config to HumanoidController")
		if not HumanoidController then
			return
		end
		print("Applying sprint config to HumanoidController")
		HumanoidController:SetWalkSpeed(self.Config.WalkSpeed)
	end

	if Character then
		onCharacterAdded(Character)
	end

	local function onSprintAction(_actionName: string, inputState: Enum.UserInputState, _inputObject: InputObject)
		if inputState == Enum.UserInputState.Begin then
			self:SetSprinting(true)
		elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
			self:SetSprinting(false)
		end

		return Enum.ContextActionResult.Pass
	end

	ContextActionService:BindAction(ACTION_NAME, onSprintAction, true, Enum.KeyCode.LeftShift, Enum.KeyCode.ButtonL3)
	ContextActionService:SetTitle(ACTION_NAME, "Run")
	ContextActionService:SetPosition(ACTION_NAME, self.Config.TouchButtonPosition)


	LocalPlayer.CharacterAdded:Connect(onCharacterAdded)

	print("✓ SprintController initialized")
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
	return self.IsSprinting
end

function SprintController:GetConfig(): SprintConfig
	return self.Config
end

function SprintController:SetConfig(newConfig: { [string]: any })
	for key, value in pairs(newConfig) do
		self.Config[key] = value
	end

	ContextActionService:SetPosition(ACTION_NAME, self.Config.TouchButtonPosition)
end

return SprintController
