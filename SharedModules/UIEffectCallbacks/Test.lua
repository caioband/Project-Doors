local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages = ReplicatedStorage:WaitForChild("ExternalPackages")
local TweenService = game:GetService("TweenService")
local ezvisualz = require(Packages:WaitForChild("ezvisualz"))

local OriginCFrameHover = {}
local OriginCFrameClick = {}
local HoverEffects = setmetatable({}, {__mode = "k"})

local SHINE_TWEEN_INFO = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local SHINE_GRADIENT = ColorSequence.new(Color3.fromRGB(255, 255, 255))
local SHINE_TRANSPARENCY = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 1),
    NumberSequenceKeypoint.new(0.2, 0.95),
    NumberSequenceKeypoint.new(0.5, 0.15),
    NumberSequenceKeypoint.new(0.8, 0.95),
    NumberSequenceKeypoint.new(1, 1),
})

local function destroyHoverEffect(guiObject)
    local effect = HoverEffects[guiObject]
    if not effect then
        return
    end

    if effect.tween then
        effect.tween:Cancel()
    end
    if effect.gradient then
        effect.gradient:Destroy()
    end
    if effect.container then
        effect.container:Destroy()
    end

    HoverEffects[guiObject] = nil
end

local function createHoverEffect(guiObject)
    local container = Instance.new("Frame")
    container.Name = "UIEffectHoverShine"
    container.BackgroundTransparency = 1
    container.BorderSizePixel = 0
    container.ClipsDescendants = true
    container.AnchorPoint = Vector2.new(0.5, 0.5)
    container.Position = UDim2.fromScale(0.5, 0.5)
    container.Size = UDim2.fromScale(1, 1)
    container.ZIndex = guiObject.ZIndex + 1
    container.Parent = guiObject

    local shine = Instance.new("Frame")
    shine.Name = "Shine"
    shine.AnchorPoint = Vector2.new(0.5, 0.5)
    shine.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    shine.BackgroundTransparency = 0.4
    shine.BorderSizePixel = 0
    shine.Position = UDim2.fromScale(-0.18, 0.5)
    shine.Rotation = -18
    shine.Size = UDim2.fromScale(0.05, 0.8)
    shine.ZIndex = container.ZIndex
    shine.Parent = container

    local gradient = ezvisualz.Gradient.new(shine, SHINE_GRADIENT, SHINE_TRANSPARENCY)
    gradient:SetRotation(0, 1)

    return {
        container = container,
        shine = shine,
        gradient = gradient,
        tween = nil,
    }
end

local function getHoverEffect(guiObject)
    destroyHoverEffect(guiObject)

    local effect = createHoverEffect(guiObject)
    HoverEffects[guiObject] = effect
    return effect
end

return {
    MouseEnter = function(guiObject)
        local Parent = guiObject:FindFirstAncestorWhichIsA("Part")
        local SurfaceGui = guiObject:FindFirstAncestorWhichIsA("SurfaceGui")
        local CurrentCamera = workspace.CurrentCamera
        if not OriginCFrame[Parent] then
            OriginCFrame[Parent] = Parent.CFrame
        end

        OriginCFrameHover[Parent] = Parent.CFrame

        local effect = getHoverEffect(guiObject)
        effect.tween = TweenService:Create(effect.shine, SHINE_TWEEN_INFO, {
            Position = UDim2.fromScale(1.35, 0.5),
        })
        effect.tween.Completed:Connect(function()
            destroyHoverEffect(guiObject)
        end)
        effect.tween:Play()

        TweenService:Create(Parent, TweenInfo.new(1, Enum.EasingStyle.Bounce, Enum.EasingDirection.Out), {CFrame = CFrame.lookAt(Parent.Position, CurrentCamera.CFrame.Position)}):Play() 
        TweenService:Create(SurfaceGui, TweenInfo.new(.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Brightness = 4}):Play()
    end,
    MouseLeave = function(guiObject)
        destroyHoverEffect(guiObject)

        local Parent = guiObject:FindFirstAncestorWhichIsA("Part")
        TweenService:Create(Parent, TweenInfo.new(1, Enum.EasingStyle.Bounce, Enum.EasingDirection.Out), {CFrame = OriginCFrame[Parent]}):Play()
    end,
}