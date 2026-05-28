local ReplicatedFirst = game:GetService("ReplicatedFirst")


local Core = require(script:WaitForChild("Core"))
local UIManager = require(script:WaitForChild("UIManager"))

local Preloader = Core.new()
local AssetsLoadedCount = 0
local TotalAssets = 0
ReplicatedFirst:RemoveDefaultLoadingScreen()

UIManager:Enable()
UIManager:SetCurrentStepText("Preloader")
Preloader:AddAssetsToPreload(workspace:WaitForChild("Menu"):GetDescendants())

Preloader.PreloadStarted:Connect(function(totalAssets)
    print("Preload started", totalAssets)
    TotalAssets = totalAssets
    UIManager:CreateLoadingDots(math.max(totalAssets, 20), 0.2)
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
end)

Preloader:Start()