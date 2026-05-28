local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local DeviceController = require(script.Parent:WaitForChild("DeviceController"))

local ScenarioController = {}

local LOOK_DISTANCE = 5
local BOB_HEIGHT = 0.1
local BOB_SPEED = 0.2
local CAMERA_SWAY_STRENGTH = 0.03
local MAX_SWAY_ANGLE = math.rad(30)
local CAMERA_SWAY_SMOOTHNESS = 1

function ScenarioController:SetupReferences()
    self.currentCamera = Workspace.CurrentCamera
    self.logo = Workspace:WaitForChild("MenuUI3D"):WaitForChild("Logo")
    self.logoBasePosition = self.logo.Position
    self.currentCameraOffset = CFrame.new()

    local camerasFolder = Workspace:FindFirstChild("Cameras")
    self.menuCameraPart = camerasFolder and camerasFolder:FindFirstChild("Menu")
end

function ScenarioController:GetMouseCameraOffset()
    if not DeviceController:IsPC() or not self.currentCamera then
        return CFrame.new()
    end

    local viewportSize = self.currentCamera.ViewportSize

    if viewportSize.X <= 0 or viewportSize.Y <= 0 then
        return CFrame.new()
    end

    local mouseLocation = UserInputService:GetMouseLocation()
    local normalizedX = ((mouseLocation.X / viewportSize.X) - 0.5) * 2
    local normalizedY = ((mouseLocation.Y / viewportSize.Y) - 0.5) * 2
    local yawOffset = -normalizedX * MAX_SWAY_ANGLE * CAMERA_SWAY_STRENGTH
    local pitchOffset = -normalizedY * MAX_SWAY_ANGLE * CAMERA_SWAY_STRENGTH

    return CFrame.Angles(pitchOffset, yawOffset, 0)
end

function ScenarioController:UpdateCamera(deltaTime)
    self.currentCamera = Workspace.CurrentCamera or self.currentCamera

    if not self.currentCamera or self.currentCamera.CameraType ~= Enum.CameraType.Scriptable then
        return
    end

    local baseCameraCFrame = self.menuCameraPart and self.menuCameraPart.CFrame or self.currentCamera.CFrame
    local targetCameraOffset = self:GetMouseCameraOffset()
    local alpha = 1 - math.exp(-CAMERA_SWAY_SMOOTHNESS * deltaTime)

    self.currentCameraOffset = self.currentCameraOffset:Lerp(targetCameraOffset, alpha)

    self.currentCamera.CFrame = baseCameraCFrame * self.currentCameraOffset
end

function ScenarioController:UpdateLogo()
    if not self.currentCamera or not self.logo or not self.logo.Parent then
        return
    end

    local bobOffset = math.sin(time() * BOB_SPEED) * BOB_HEIGHT
    local currentPosition = self.logoBasePosition + Vector3.new(0, bobOffset, 0)
    local lookTarget = self.currentCamera.CFrame.Position + (self.currentCamera.CFrame.LookVector * LOOK_DISTANCE)

    self.logo.CFrame = CFrame.lookAt(currentPosition, lookTarget)
end

function ScenarioController:StartRenderLoop()

    if self.renderConnection then
        self.renderConnection:Disconnect()
    end

    self.renderConnection = RunService.RenderStepped:Connect(function(deltaTime)
        self:UpdateCamera(deltaTime)
        self:UpdateLogo()
    end)
end

function ScenarioController:Start()
    self:SetupReferences()
    self:StartRenderLoop()
end

return ScenarioController