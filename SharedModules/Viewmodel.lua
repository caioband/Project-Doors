--!strict

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")

local Viewmodel = {}
Viewmodel.__index = Viewmodel

export type ViewmodelConfig = {
	EnableHeadBob: boolean?,
	EnableCameraSway: boolean?,
	BaseWalkSpeed: number?,
	HeadBobSpeed: number?,
	HeadBobIntensity: number?,
	HeadBobRotationIntensity: number?,
	HeadBobLeanIntensity: number?,
	HeadBobMaxLeanSide: number?,
	HeadBobMaxLeanForward: number?,
	HeadBobLeanDebounce: number?,
	HeadBobIdleSpeed: number?,
	HeadBobIdleIntensity: number?,
	SwayIntensity: number?,
	DefaultFOV: number?,
	SprintFOV: number?,
	FOVTransitionSpeed: number?,
}

local DEFAULT_CONFIG: ViewmodelConfig = {
	EnableHeadBob = true,
	EnableCameraSway = true,
	BaseWalkSpeed = 16,
	HeadBobSpeed = 10,
	HeadBobIntensity = 0.05,
	HeadBobRotationIntensity = 0.01,
	HeadBobLeanIntensity = 0.04,
	HeadBobMaxLeanSide = 0.06,
	HeadBobMaxLeanForward = 0.04,
	HeadBobLeanDebounce = 0.15,
	HeadBobIdleSpeed = 1.5,
	HeadBobIdleIntensity = 0.008,
	SwayIntensity = 0.02,
	DefaultFOV = 70,
	SprintFOV = 80,
	FOVTransitionSpeed = 5,
}

function Viewmodel.new(config: ViewmodelConfig?)
	local self = setmetatable({}, Viewmodel)

	self.Config = config or DEFAULT_CONFIG
	for key, value in pairs(DEFAULT_CONFIG) do
		if self.Config[key] == nil then
			self.Config[key] = value
		end
	end

	self.Player = Players.LocalPlayer
	self.Camera = workspace.CurrentCamera
	self.Character = nil
	self.Humanoid = nil
	self.HumanoidRootPart = nil

	self.IsRunning = false
	self.FreeMouse = false
	self.BaseWalkSpeed = 16
	self.CurrentBobTime = 0
	self.IdleBobTime = 0
	self.CurrentFOV = self.Config.DefaultFOV
	self.SwayRotation = Vector3.new(0, 0, 0)
	self.LeanRotation = Vector3.new(0, 0, 0)
	self.PrevForwardSpeed = 0
	self.PrevStrafeSign = 0
	self.PrevForwardSign = 0
	self.LeanDebounceTimer = 0

	self.Connections = {}

	return self
end

function Viewmodel:Start()
	self:_setupCharacter(self.Player.Character or self.Player.CharacterAdded:Wait())

	table.insert(self.Connections, self.Player.CharacterAdded:Connect(function(character)
		self:_setupCharacter(character)
	end))

	RunService:BindToRenderStep(
		"ViewmodelUpdate",
		Enum.RenderPriority.Camera.Value + 1,
		function(deltaTime)
			self:_update(deltaTime)
		end
	)
end

function Viewmodel:_setupCharacter(character: Model)
	self.Character = character
	self.Humanoid = character:WaitForChild("Humanoid") :: Humanoid
	self.HumanoidRootPart = character:WaitForChild("HumanoidRootPart") :: BasePart
	self.BaseWalkSpeed = self.Config.BaseWalkSpeed :: number

	-- Force first person
	self.Humanoid.CameraOffset = Vector3.new(0, 0, 0)
	self.Camera.CameraType = Enum.CameraType.Custom

	-- Hide character parts for first person
	for _, part in ipairs(character:GetDescendants()) do
		if part:IsA("BasePart") and part.Name ~= "Head" then
			part.LocalTransparencyModifier = 1
		end
	end
end

function Viewmodel:_update(deltaTime: number)
	if not self.Character or not self.Humanoid or not self.HumanoidRootPart then
		return
	end

	-- A câmera padrão do Roblox força LockCenter todo frame em primeira pessoa,
	-- então reforçamos o mouse livre aqui para não ser sobrescrito.
	if self.FreeMouse then
		if UserInputService.MouseBehavior ~= Enum.MouseBehavior.Default then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		end
	end

	-- Calculate movement velocity (horizontal only, so falling/jumping doesn't spike the bob)
	local velocity = self.HumanoidRootPart.AssemblyLinearVelocity
	local horizontalVelocity = Vector3.new(velocity.X, 0, velocity.Z)
	local speed = horizontalVelocity.Magnitude

	-- Determine running state from the Humanoid's WalkSpeed
	self.IsRunning = self.Humanoid.WalkSpeed > self.BaseWalkSpeed + 0.01

	-- Velocity in the character's local space + forward acceleration.
	-- The forward/back lean reacts to acceleration (a transient dip when you start/stop)
	-- instead of steady velocity, so it never holds a sustained pitch that fights aim.
	local localVel = self.HumanoidRootPart.CFrame:VectorToObjectSpace(horizontalVelocity)
	local forwardSpeed = -localVel.Z -- +Z is backwards in Roblox, so forward = -Z
	local forwardAccel = (forwardSpeed - self.PrevForwardSpeed) / math.max(deltaTime, 1e-4)
	self.PrevForwardSpeed = forwardSpeed

	-- Debounce against lean-pumping: if the player reverses movement direction (on either
	-- axis) faster than HeadBobLeanDebounce, refuse to write a new lean and let it decay back
	-- to the original orientation. Stops them from spamming inputs to creep the camera around.
	local strafeSign = math.abs(localVel.X) > 1 and math.sign(localVel.X) or 0
	local forwardSign = math.abs(forwardSpeed) > 1 and math.sign(forwardSpeed) or 0
	local reversed = (strafeSign ~= 0 and self.PrevStrafeSign ~= 0 and strafeSign ~= self.PrevStrafeSign)
		or (forwardSign ~= 0 and self.PrevForwardSign ~= 0 and forwardSign ~= self.PrevForwardSign)

	self.LeanDebounceTimer = math.max(0, self.LeanDebounceTimer - deltaTime)

	local suppressLean = false
	if reversed then
		-- A reversal within the debounce window means they're flip-flopping: lock the lean.
		if self.LeanDebounceTimer > 0 then
			suppressLean = true
		end
		self.LeanDebounceTimer = self.Config.HeadBobLeanDebounce :: number
	end

	if strafeSign ~= 0 then
		self.PrevStrafeSign = strafeSign
	end
	if forwardSign ~= 0 then
		self.PrevForwardSign = forwardSign
	end

	local bobOffset = Vector3.new(0, 0, 0)
	local bobRotation = Vector3.new(0, 0, 0)
	local targetLean = Vector3.new(0, 0, 0)

	-- Head bob
	if self.Config.EnableHeadBob then
		local speedRatio = speed / math.max(self.BaseWalkSpeed, 1)

		if speed < 0.5 then
			-- Idle: subtle breathing bob when the player is essentially still
			self.IdleBobTime += deltaTime * (self.Config.HeadBobIdleSpeed :: number)
			self.CurrentBobTime *= 0.9
			bobOffset = Vector3.new(0, math.sin(self.IdleBobTime) * (self.Config.HeadBobIdleIntensity :: number), 0)
		else
			local dynSpeed = (self.Config.HeadBobSpeed :: number) * speedRatio
			local dynIntensity = (self.Config.HeadBobIntensity :: number) * speedRatio
			local dynRotIntensity = (self.Config.HeadBobRotationIntensity :: number) * speedRatio

			if self.IsRunning then
				dynIntensity *= 1.5
				dynRotIntensity *= 1.5
			end

			self.CurrentBobTime += deltaTime * dynSpeed

			local bobX = math.sin(self.CurrentBobTime) * dynIntensity
			local bobY = math.abs(math.sin(self.CurrentBobTime * 2)) * dynIntensity
			bobOffset = Vector3.new(bobX, bobY, 0)

			-- Tilt the camera in sync with the bob cycle (head roll + slight pitch)
			bobRotation = Vector3.new(
				math.sin(self.CurrentBobTime * 2) * dynRotIntensity,
				0,
				math.sin(self.CurrentBobTime) * dynRotIntensity
			)

			-- Lean the camera toward the direction the player is moving (unless debounced).
			if not suppressLean then
				local leanIntensity = self.Config.HeadBobLeanIntensity :: number
				local maxLeanForward = self.Config.HeadBobMaxLeanForward :: number
				local maxLeanSide = self.Config.HeadBobMaxLeanSide :: number

				-- Pitch (frente/trás): a transient dip driven by forward acceleration, so it
				-- returns to neutral while walking steadily (no sustained pitch that fights aim).
				local pitchLean = math.clamp(-forwardAccel * leanIntensity * 0.02, -maxLeanForward, maxLeanForward)

				-- Roll (direita/esquerda): bank into the strafe direction.
				local strafeRatio = math.clamp(localVel.X / math.max(self.BaseWalkSpeed, 1), -1, 1)
				local rollLean = math.clamp(-strafeRatio * leanIntensity, -maxLeanSide, maxLeanSide)

				targetLean = Vector3.new(pitchLean, 0, rollLean)
			end
		end
	end

	-- Smoothly ease the lean toward its target so it builds/releases gently
	local leanAlpha = 1 - math.exp(-8 * deltaTime)
	self.LeanRotation = self.LeanRotation:Lerp(targetLean, leanAlpha)
	bobRotation += self.LeanRotation

	-- Camera sway based on mouse movement (desativado enquanto o mouse estiver livre,
	-- já que o cursor não está travado no centro e o delta não representa movimento de câmera)
	local swayRotation = Vector3.new(0, 0, 0)
	if self.Config.EnableCameraSway and not self.FreeMouse then
		local mouseDelta = UserInputService:GetMouseDelta()
		local intensity = self.Config.SwayIntensity

		local targetSway = Vector3.new(
			math.clamp(-mouseDelta.Y * intensity, -0.08, 0.08),
			math.clamp(-mouseDelta.X * intensity, -0.08, 0.08),
			math.clamp(mouseDelta.X * intensity * 0.5, -0.04, 0.04)
		)

		local alpha = 1 - math.exp(-12 * deltaTime)
		self.SwayRotation = self.SwayRotation:Lerp(targetSway, alpha)
		swayRotation = self.SwayRotation
	end

	-- Apply head bob (position + rotation) and camera sway directly to the camera CFrame.
	-- This is computed fresh on top of the base camera CFrame every frame, so it can't get
	-- "stuck" by Humanoid.CameraOffset being reset on humanoid state changes (e.g. sprint toggles).
	local bobCFrame = CFrame.new(bobOffset) * CFrame.Angles(bobRotation.X, bobRotation.Y, bobRotation.Z)
	local swayCFrame = CFrame.Angles(swayRotation.X, swayRotation.Y, swayRotation.Z)
	self.Camera.CFrame = self.Camera.CFrame * bobCFrame * swayCFrame

	-- Update FOV for sprint
	local targetFOV = self.IsRunning and self.Config.SprintFOV or self.Config.DefaultFOV
	self.CurrentFOV = self.CurrentFOV + (targetFOV - self.CurrentFOV) * self.Config.FOVTransitionSpeed * deltaTime
	self.Camera.FieldOfView = self.CurrentFOV
end

function Viewmodel:SetFirstPerson(enabled: boolean)
	if not self.Player then return end

	if enabled then
		self.Player.CameraMaxZoomDistance = 0.5
		self.Player.CameraMinZoomDistance = 0.5

		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		UserInputService.MouseIconEnabled = false
	else
		self.Player.CameraMaxZoomDistance = 128
		self.Player.CameraMinZoomDistance = 0.5

		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
	end
end

function Viewmodel:SetFreeMouse(enabled: boolean)
	self.FreeMouse = enabled

	if enabled then
		-- Libera o mouse e restaura o ícone/cursor padrão
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
	else
		-- Volta a travar o mouse no centro (primeira pessoa)
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		UserInputService.MouseIconEnabled = false
	end
end

function Viewmodel:ToggleFreeMouse(): boolean
	self:SetFreeMouse(not self.FreeMouse)
	return self.FreeMouse
end

function Viewmodel:SetConfig(newConfig: ViewmodelConfig)
	for key, value in pairs(newConfig) do
		self.Config[key] = value
	end
end

function Viewmodel:Destroy()
	for _, connection in ipairs(self.Connections) do
		connection:Disconnect()
	end

	self.Connections = {}

	-- Reset camera
	if self.Camera then
		RunService:UnbindFromRenderStep("ViewmodelUpdate")
		self.Camera.CameraType = Enum.CameraType.Custom
		self.Camera.FieldOfView = 70
	end

	-- Restore character visibility
	if self.Character then
		for _, part in ipairs(self.Character:GetDescendants()) do
			if part:IsA("BasePart") then
				part.LocalTransparencyModifier = 0
			end
		end
	end

	if self.Player then
		self.Player.CameraMaxZoomDistance = 128
		self.Player.CameraMinZoomDistance = 0.5

		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
	end
end

return Viewmodel
