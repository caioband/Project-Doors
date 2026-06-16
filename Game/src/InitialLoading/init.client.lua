local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local Character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
local Humanoid = Character:WaitForChild("Humanoid")
local Controls = require(LocalPlayer.PlayerScripts:WaitForChild("PlayerModule")):GetControls()
local Core = require(ReplicatedFirst:WaitForChild("SharedModulesFirst"):WaitForChild("Preloader"))
local UIManager = require(script:WaitForChild("UIManager"))
local UIEffectCallbacks = require(
    ReplicatedStorage
        :WaitForChild("Shared")
        :WaitForChild("SharedModules")
        :WaitForChild("UIEffectCallbacks")
)

local Preloader = Core.new()
local AssetsLoadedCount = 0
local TotalAssets = 0
ReplicatedFirst:RemoveDefaultLoadingScreen()

UIEffectCallbacks.Start()
UIManager:Enable()
Controls:Disable()

local WalkSpeedValue = Humanoid.WalkSpeed
local JumpPowerValue = Humanoid.JumpPower
local JumpHeightValue = Humanoid.JumpHeight
local AutoRotateValue = Humanoid.AutoRotate

Humanoid.WalkSpeed = 0
Humanoid.JumpPower = 0
Humanoid.JumpHeight = 0
Humanoid.AutoRotate = false

UIManager:SetCurrentStepText("Preloader")
Preloader:AddAssetsToPreload(LocalPlayer.PlayerGui:WaitForChild("Loading"):GetDescendants())

Preloader.PreloadStarted:Connect(function(totalAssets)
    TotalAssets = totalAssets
    UIManager:CreateLoadingDots(math.min(totalAssets, 20), 0.2)
end)

Preloader.SectionAssetLoaded:Connect(function(typeName, assetIndex, sectionAssetCount, sectionIndex, sectionCount, assetId, assetFetchStatus)
    UIManager:SetCurrentStepText(typeName)
    AssetsLoadedCount += 1
    UIManager:SetProgressionText(math.floor((AssetsLoadedCount / TotalAssets) * 100) .. "%")
    local TotalDots = UIManager:GetTotalDots()
    local DotsToActivate = math.floor((AssetsLoadedCount / sectionAssetCount) * TotalDots)
    for i = 1, DotsToActivate do
        task.wait(0.05)
        UIManager:SetDotState(i, "On")
    end
end)

Preloader.PreloadFinished:Connect(function()
    while UIManager.DotsAnimating do
        task.wait(0.1)
    end
    UIManager:LoadFinished()
    Humanoid.WalkSpeed = WalkSpeedValue
    Humanoid.JumpPower = JumpPowerValue
    Humanoid.JumpHeight = JumpHeightValue
    Humanoid.AutoRotate = AutoRotateValue
end)

Preloader:Start()