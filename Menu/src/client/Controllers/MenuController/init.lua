local MenuController = {}
local MenuUI3D = workspace:WaitForChild("MenuUI3D")
local Player = game.Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")
local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ConnectionPlus = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SharedModules"):WaitForChild("ConnectionPlus"))
local HudFramesVisibilityCallbacks = require(script:WaitForChild("HudFramesVisibilityCallbacks"))


local RoomOptionsController 

local CurrentBlur

function MenuController:ObserveFrameVisibilityAndExecute(frame : Frame, isVisible : boolean, visibleCallback : () -> (), invisibleCallback : () -> ())
    
    if frame then 
        if isVisible then
            if CurrentBlur then
                TweenService:Create(CurrentBlur, TweenInfo.new(0.5), {Size = 24}):Play()
            end
            if visibleCallback then
                visibleCallback()
            end
        else
            if CurrentBlur then
                TweenService:Create(CurrentBlur, TweenInfo.new(0.5), {Size = 0}):Play()
            end
            if invisibleCallback then
                invisibleCallback()
            end
        end
    end
end

local function GetButtonPartFromMenuUI3D(buttonName) : Part
    return MenuUI3D:WaitForChild(buttonName)
end


function MenuController:SetupPlayOptions()
    local Hud = PlayerGui:WaitForChild("Hud")
    local RoomOptions = Hud:WaitForChild("RoomOptions")

    RoomOptions.Visible = true
    self:UnBindMenuButtons()
    RoomOptionsController:BindOptionsButtons()
end

function MenuController:PlayButtonCallback()
    self:SetupPlayOptions()
end

function MenuController:BindMenuButtons()

    local PlayPart = MenuUI3D:WaitForChild("Play")
    local PlayButton = PlayPart:FindFirstChildWhichIsA("ImageButton", true)

    local CreditsPart = MenuUI3D:WaitForChild("Credits") 
    local CreditsButton = CreditsPart:FindFirstChildWhichIsA("ImageButton", true)

    if PlayButton then
        PlayButton.Active = true

        if PlayButton:GetAttribute("IgnoreCallback") then 
            PlayButton:SetAttribute("IgnoreCallback", nil)
        end

        ConnectionPlus:ConnectWithInfo(PlayButton,"Activated", PlayButton.Activated, function()
            self:PlayButtonCallback()
        end)

    end
    if CreditsButton then
        CreditsButton.Active = true
       
        if CreditsButton:GetAttribute("IgnoreCallback") then 
            CreditsButton:SetAttribute("IgnoreCallback", nil)
        end

        ConnectionPlus:ConnectWithInfo(CreditsButton,"Activated", CreditsButton.Activated, function()
            print("Credits Button Clicked")
        end)
    end
end

function MenuController:UnBindMenuButtons()
    local PlayPart = MenuUI3D:WaitForChild("Play")
    local PlayButton = PlayPart:FindFirstChildWhichIsA("ImageButton", true)

    local CreditsPart = MenuUI3D:WaitForChild("Credits") 
    local CreditsButton = CreditsPart:FindFirstChildWhichIsA("ImageButton", true)

    if PlayButton then
        PlayButton.Active = false

        PlayButton:SetAttribute("IgnoreCallback", true)
        ConnectionPlus:Disconnect(PlayButton,"Activated")
    end
    if CreditsButton then
        CreditsButton.Active = false
        
        CreditsButton:SetAttribute("IgnoreCallback", true)
        ConnectionPlus:Disconnect(CreditsButton,"Activated")
    end
end

function MenuController:BindVisibilityForChildren(object : Instance)

    if not object then return end

    self:SetupBlurEffect()

    for i,v in pairs(object:GetChildren()) do
        if v:IsA("Frame") then
            v:GetPropertyChangedSignal("Visible"):Connect(function()
                local hasVisibleSiblings = false
                task.wait()
                for j,k in pairs(object:GetChildren()) do
                    if k ~= v and k.Visible == true then 
                        hasVisibleSiblings = true
                        break
                    end
                end
                if hasVisibleSiblings then return end
                self:ObserveFrameVisibilityAndExecute(v, v.Visible, HudFramesVisibilityCallbacks["Visible"][v.Name] , HudFramesVisibilityCallbacks["Invisible"][v.Name])
            end)
        end
    end
end

function MenuController:SetupBlurEffect()
    local Blur = Instance.new("BlurEffect")
    Blur.Size = 0
    Blur.Parent = Lighting
    CurrentBlur = Blur
end

function MenuController:Start()
    local Hud = PlayerGui:WaitForChild("Hud")
    
    RoomOptionsController = self.GetController("RoomOptionsController")

    self:BindVisibilityForChildren(Hud)
    self:BindMenuButtons()
end 

return MenuController