--!strict

local Players = game:GetService("Players")

local LocalPlayer = Players.LocalPlayer

local DEFAULT_PROPERTIES = {
	WalkSpeed = 8,
	JumpPower = 50,
	JumpHeight = 7.2,
	AutoRotate = true,
	UseJumpPower = true,
}

local HumanoidController = {}
HumanoidController.Humanoid = nil :: Humanoid?
HumanoidController.Overrides = {}

function HumanoidController:Start()
	local function onCharacterAdded(character: Model)
		local humanoid = character:WaitForChild("Humanoid") :: Humanoid
		self.Humanoid = humanoid

		self:ApplyOverrides()
	end

	if LocalPlayer.Character then
		onCharacterAdded(LocalPlayer.Character)
	end

	LocalPlayer.CharacterAdded:Connect(onCharacterAdded)

	print("✓ HumanoidController initialized")
end

function HumanoidController:GetHumanoid(): Humanoid?
	return self.Humanoid
end

function HumanoidController:ApplyOverrides()
	local humanoid = self.Humanoid
	if not humanoid then
		return
	end

	for property, value in pairs(self.Overrides) do
		(humanoid :: any)[property] = value
	end
end

function HumanoidController:SetProperty(property: string, value: any)
	print("Setting Humanoid property:", property, "to", value)
	self.Overrides[property] = value

	local humanoid = self.Humanoid
	if humanoid then
		(humanoid :: any)[property] = value
	end
end

function HumanoidController:ResetProperty(property: string)
	self.Overrides[property] = nil

	local humanoid = self.Humanoid
	if humanoid and DEFAULT_PROPERTIES[property] ~= nil then
		(humanoid :: any)[property] = DEFAULT_PROPERTIES[property]
	end
end

function HumanoidController:ResetAll()
	self.Overrides = {}

	local humanoid = self.Humanoid
	if not humanoid then
		return
	end

	for property, value in pairs(DEFAULT_PROPERTIES) do
		(humanoid :: any)[property] = value
	end
end

function HumanoidController:SetWalkSpeed(walkSpeed: number)
	self:SetProperty("WalkSpeed", walkSpeed)
end

function HumanoidController:SetJumpPower(jumpPower: number)
	self:SetProperty("UseJumpPower", true)
	self:SetProperty("JumpPower", jumpPower)
end

function HumanoidController:SetJumpHeight(jumpHeight: number)
	self:SetProperty("UseJumpPower", false)
	self:SetProperty("JumpHeight", jumpHeight)
end

function HumanoidController:SetAutoRotate(enabled: boolean)
	self:SetProperty("AutoRotate", enabled)
end

return HumanoidController
