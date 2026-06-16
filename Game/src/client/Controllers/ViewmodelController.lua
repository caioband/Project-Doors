--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Viewmodel = require(ReplicatedStorage.Shared.SharedModules.Viewmodel)

local ViewmodelController = {}

function ViewmodelController:Start()
	-- Configuração customizável
	local config = {
		EnableHeadBob = true,
		EnableCameraSway = true,
		BaseWalkSpeed = 8,
		HeadBobSpeed = 3,
		HeadBobIntensity = 0.0001,
		HeadBobRotationIntensity = 0.0005,
		HeadBobLeanIntensity = 0.01,
		HeadBobMaxLeanForward = 0.001,
		HeadBobMaxLeanSide = 1,
		HeadBobLeanDebounce = 1,
		SwayIntensity = 0.01,
		DefaultFOV = 70,
		SprintFOV = 80,
		FOVTransitionSpeed = 5,
	}

	self.ViewmodelInstance = Viewmodel.new(config)
	self.ViewmodelInstance:Start()
	self.ViewmodelInstance:SetFirstPerson(true)

	print("✓ ViewmodelController initialized")
end

function ViewmodelController:GetViewmodel()
	return self.ViewmodelInstance
end

return ViewmodelController
