--[[

 _______  _______  ___   _______  _______  _______  __    _  ______  
|       ||   _   ||   | |       ||  _    ||   _   ||  |  | ||      | 
|       ||  |_|  ||   | |   _   || |_|   ||  |_|  ||   |_| ||  _    |
|       ||       ||   | |  | |  ||       ||       ||       || | |   |
|      _||       ||   | |  |_|  ||  _   | |       ||  _    || |_|   |
|     |_ |   _   ||   | |       || |_|   ||   _   || | |   ||       |
|_______||__| |__||___| |_______||_______||__| |__||_|  |__||______| 

Made by Caio Bandeira

WARNING: I'm not proud of what is written below... yet.

Delete this warning when this component looks better (if that day ever comes).

]]


local Component = {}
local PlayerGui = game.Players.LocalPlayer:WaitForChild("PlayerGui")
local ChooseComponent = PlayerGui:WaitForChild("SharedGuis"):WaitForChild("ChooseComponent")
local TweenService = game:GetService("TweenService")

local Types = {"Center", "Corner"}
local connections = {}
local cornerButtonsconnections = {}


local CurrentBlur = {}
local PlayerGuiVisibilities = {}

Component.CurrentCornerStack = 0
Component.CornerStack = {}
Component.CornerFirstPos = ChooseComponent.Frame:WaitForChild("Corner").Position
Component.CornerYOffset = 0.15

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
        local Tween = TweenService:Create(Frame, TweenInfo.new(0.5), {BackgroundTransparency = 1})
        Tween:Play()
    end
    
    if CurrentBlur.Instance then
        local blur = CurrentBlur.Instance
        local createdByComponent = not CurrentBlur.Existed
        -- Blurs criados aqui voltam a 0 e sao destruidos; blurs que ja existiam
        -- (ex: o blur da loja) sao restaurados ao tamanho original para nao os apagar.
        local targetSize = createdByComponent and 0 or CurrentBlur.Size
        local Tween = TweenService:Create(blur, TweenInfo.new(0.5), {Size = targetSize})
        Tween:Play()
        if createdByComponent then
            Tween.Completed:Once(function()
                blur:Destroy()
            end)
        end
        CurrentBlur = {}
    end
end

function ClearConnections()
    for _, connection in ipairs(connections) do
        connection:Disconnect()
        connection = nil
    end
    connections = {}
end

function InsertCornerComponent(data : ComponentData)
    local ComponentObject = ChooseComponent.Frame:WaitForChild("Corner"):Clone()
    local buttons = ComponentObject:WaitForChild("Buttons")
    local confirm = buttons:WaitForChild("Confirm")
    local cancel = buttons:WaitForChild("Cancel")

    local function releaseComponent()
        local tween = TweenService:Create(ComponentObject, TweenInfo.new(0.3), {Position = UDim2.fromScale(ComponentObject.Position.X.Scale + 1, ComponentObject.Position.Y.Scale), ImageTransparency = 1})
        tween:Play()
        tween.Completed:Wait()
        ComponentObject:Destroy()
        table.remove(Component.CornerStack, table.find(Component.CornerStack, ComponentObject))
    end

    table.insert(Component.CornerStack, 1 ,ComponentObject)

    for i,v in pairs(Component.CornerStack) do

        if data.confirmText then
            confirm.Visible = true
        end

        if data.cancelText then
            cancel.Visible = true
        end

        if i > 1 then 
            local TargetPos = UDim2.fromScale(v.Position.X.Scale, v.Position.Y.Scale - (v.Size.Y.Scale/2) - Component.CornerYOffset)
            local tween = TweenService:Create(v, TweenInfo.new(0.3), {Position = TargetPos})
            task.delay(1/10*i, function()
                v.Visible = true
                tween:Play() 
            end)
        else
            local TargetPos = Component.CornerFirstPos
            v.Name = "Corner"..#Component.CornerStack
            local tween = TweenService:Create(v, TweenInfo.new(0.3), {Position = TargetPos})
            task.delay(.2, function()
                v.Parent = ChooseComponent:WaitForChild("Frame")
                v.Visible = true
                v.Position = UDim2.fromScale(Component.CornerFirstPos.X.Scale + (v.Size.X.Scale/2), Component.CornerFirstPos.Y.Scale)
                tween:Play()
            end)
        end
    end

    local confirmConn
    local cancelConn

    confirmConn = confirm.Activated:Once(function()
        if data.confirmCallback then
            data.confirmCallback()
        end
        releaseComponent()
        cancelConn:Disconnect()
        confirmConn:Disconnect()
        cancelConn = nil
        confirmConn = nil
    end)

    cancelConn = cancel.Activated:Once(function()
        if data.cancelCallback then
            data.cancelCallback()
        end
        releaseComponent()
        cancelConn:Disconnect()
        confirmConn:Disconnect()
        cancelConn = nil
        confirmConn = nil
    end)

    if data.delay then
        task.delay(data.delay, function()
            local tween = TweenService:Create(ComponentObject, TweenInfo.new(0.3), {Position = UDim2.fromScale(ComponentObject.Position.X.Scale + 1, ComponentObject.Position.Y.Scale), ImageTransparency = 1})
            tween:Play()
            tween.Completed:Wait()
            ComponentObject:Destroy()
            table.remove(Component.CornerStack, table.find(Component.CornerStack, ComponentObject))
        end)
    end
end

function HandleOpenEffect(component)
    local Lighting = game:GetService("Lighting")
    local Blur = Lighting:FindFirstChildWhichIsA("BlurEffect")
    local Frame = component.Parent

    if Frame then
        local Tween = TweenService:Create(Frame, TweenInfo.new(0.5), {BackgroundTransparency = 0.7})
        Tween:Play()
    end

    if Blur then
        CurrentBlur = {
            Instance = Blur,
            Size = Blur.Size,
            Existed = true
        }
        
        local Tween = TweenService:Create(Blur, TweenInfo.new(0.5), {Size = 24})
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

        local Tween = TweenService:Create(NewBlur, TweenInfo.new(0.5), {Size = 24})
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
    

    local Component = PlayerGui:WaitForChild("SharedGuis"):WaitForChild("ChooseComponent"):WaitForChild("Frame"):WaitForChild(data.type)
    Component.Content.Text = data.content


    if data.type == "Corner" then
        InsertCornerComponent(data)
    else
        Component.Visible = true
    end

    if data.confirmText then
        Component.Buttons.Confirm.Visible = true
        Component.Buttons.Confirm.TextLabel.Text = data.confirmText
    end

    if data.cancelText then
        Component.Buttons.Cancel.Visible = true
        Component.Buttons.Cancel.TextLabel.Text = data.cancelText
    end

    if data.confirmCallback then
        table.insert(connections, Component.Buttons.Confirm.Activated:Once(function()
            data.confirmCallback()
            if data.type ~= "Corner" then
                Component.Visible = false   
                HandleCloseEffect(Component)
                RestoreAllUIs()
            end
            print("callback confirmed")
            ClearConnections()
        end))
    else
        table.insert(connections, Component.Buttons.Confirm.Activated:Once(function()
            if data.type ~= "Corner" then   
                Component.Visible = false
                HandleCloseEffect(Component)
                RestoreAllUIs()
            end
            print("no callback")
            ClearConnections()
        end))
    end
        
    if data.cancelCallback then
        table.insert(connections, Component.Buttons.Cancel.Activated:Once(function()
            data.cancelCallback()
            if data.type ~= "Corner" then   
                Component.Visible = false
                HandleCloseEffect(Component)
                RestoreAllUIs()
            end
            ClearConnections()
        end))
    else
        table.insert(connections, Component.Buttons.Cancel.Activated:Once(function()
            if data.type ~= "Corner" then   
                Component.Visible = false
                HandleCloseEffect(Component)
                RestoreAllUIs()
            end
            ClearConnections()
        end))
    end

    if data.delay then
        task.delay(data.delay, function()
            if data.type ~= "Corner" then   
                Component.Visible = false
                HandleCloseEffect(Component)
                RestoreAllUIs()
            end
            ClearConnections()
        end)
    end
    if data.type ~= "Corner" then
         HandleOpenEffect(Component)
         HideAllUIs()
    end
end

return Component