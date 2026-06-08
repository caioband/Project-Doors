local Component = {}
local PlayerGui = game.Players.LocalPlayer:WaitForChild("PlayerGui")
local ChooseComponent = PlayerGui:WaitForChild("SharedGuis"):WaitForChild("ChooseComponent")
local TwweenService = game:GetService("TweenService")

local Types = {"Center", "Corner"}
local connections = {}

local CurrentBlur = {}
local PlayerGuiVisibilities = {}

type ComponentData = {
    type: string,
    delay: number?,
    content: string,
    confirmText: string?,
    cancelText: string?,
    confirmCallback: (() -> ())?,
    cancelCallback: (() -> ())?,
}


function HideAllUIs()
    for _, Gui in ipairs(PlayerGui:GetDescendants()) do
        if Gui:IsA("ScreenGui") and Gui.Enabled and Gui.Name ~= ChooseComponent.Name then
            PlayerGuiVisibilities[Gui] = true
            Gui.Enabled = false
        end
    end
end

function RestoreAllUIs()
    for Gui, WasEnabled in pairs(PlayerGuiVisibilities) do
        if WasEnabled then
            Gui.Enabled = true
        end
    end
    PlayerGuiVisibilities = {}
end


function HandleCloseEffect(component)
    local Frame = component.Parent

    if Frame then
        local Tween = TwweenService:Create(Frame, TweenInfo.new(0.5), {BackgroundTransparency = 1})
        Tween:Play()
    end
    
    if CurrentBlur.Instance then
        print("b")
        local Tween = TwweenService:Create(CurrentBlur.Instance, TweenInfo.new(0.5), {Size = 0})
        Tween:Play()
    end
end

function ClearConnections()
    for _, connection in ipairs(connections) do
        connection:Disconnect()
        connection = nil
    end
    connections = {}
end

function HandleOpenEffect(component)
    local Lighting = game:GetService("Lighting")
    local Blur = Lighting:FindFirstChildWhichIsA("BlurEffect")
    local Frame = component.Parent

    if Frame then
        local Tween = TwweenService:Create(Frame, TweenInfo.new(0.5), {BackgroundTransparency = 0.7})
        Tween:Play()
    end

    if Blur then
        CurrentBlur = {
            Instance = Blur,
            Size = Blur.Size,
            Existed = true
        }
        
        local Tween = TwweenService:Create(Blur, TweenInfo.new(0.5), {Size = 24})
        Tween:Play()
    else

        local NewBlur = Instance.new("BlurEffect")
        NewBlur.Size = 0
        NewBlur.Parent = Lighting
        NewBlur:SetAttribute("CreatedByChooseComponent", true)
        CurrentBlur = {
            Instance = NewBlur,
            Size = NewBlur.Size,
            Existed = false
        }

        local Tween = TwweenService:Create(NewBlur, TweenInfo.new(0.5), {Size = 24})
        Tween:Play()
    end
end


function Component:Show(data : ComponentData)

    assert(table.find(Types, data.type), "Invalid component type: " .. data.type)
    assert(typeof(data) == "table", "table expected for data, got " .. typeof(data))
    assert(typeof(data.type) == "string", "string expected for component type, got " .. typeof(data.type))
    assert(typeof(data.content) == "string", "string expected for content, got " .. typeof(data.content))
    assert(data.delay == nil or typeof(data.delay) == "number", "number expected for delay, got " .. typeof(data.delay))
    assert(data.confirmText == nil or typeof(data.confirmText) == "string", "string expected for confirmText, got " .. typeof(data.confirmText))
    assert(data.cancelText == nil or typeof(data.cancelText) == "string", "string expected for cancelText, got " .. typeof(data.cancelText))
    assert(data.confirmCallback == nil or typeof(data.confirmCallback) == "function", "function expected for confirmCallback, got " .. typeof(data.confirmCallback))
    assert(data.cancelCallback == nil or typeof(data.cancelCallback) == "function", "function   expected for cancelCallback, got " .. typeof(data.cancelCallback))
    

    local Component = ChooseComponent.Frame:WaitForChild(data.type)
    Component.Visible = true
    Component.Content.Text = data.content

    Component.Buttons.Confirm.TextLabel.Text = "Ok"
    Component.Buttons.Confirm.Visible = true

    if data.confirmText then
        Component.Buttons.Confirm.TextLabel.Text = data.confirmText
    end

    if data.cancelText then
        Component.Buttons.Cancel.Visible = true
        Component.Buttons.Cancel.TextLabel.Text = data.cancelText
    end

    if data.confirmCallback then
        table.insert(connections, Component.Buttons.Confirm.Activated:Once(function()
            data.confirmCallback()
            Component.Visible = false
            HandleCloseEffect(Component)
            RestoreAllUIs()
            ClearConnections()
        end))
    else
        table.insert(connections, Component.Buttons.Confirm.Activated:Once(function()
            Component.Visible = false
            HandleCloseEffect(Component)
            RestoreAllUIs()
            ClearConnections()
        end))
    end
        
    if data.cancelCallback then
        table.insert(connections, Component.Buttons.Cancel.Activated:Once(function()
            data.cancelCallback()
            Component.Visible = false
            HandleCloseEffect(Component)
            RestoreAllUIs()
            ClearConnections()
        end))
    else
        table.insert(connections, Component.Buttons.Cancel.Activated:Once(function()
            Component.Visible = false
            HandleCloseEffect(Component)
            RestoreAllUIs()
            ClearConnections()
        end))
    end

    if data.delay then
        task.delay(data.delay, function()
            Component.Visible = false
            HandleCloseEffect(Component)
            RestoreAllUIs()
            ClearConnections()
        end)
    end
    HandleOpenEffect(Component)
    HideAllUIs()
end

return Component