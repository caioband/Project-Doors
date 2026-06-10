local Component = {}

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedModules = ReplicatedStorage.Shared.SharedModules
local ExternalPackages = ReplicatedStorage.ExternalPackages

local Promise = require(ExternalPackages.promise)
local ToggleLoading = require(SharedModules.ToggleLoading)
local ChooseComponent = require(SharedModules.ChooseComponent)
local TweenService = game:GetService("TweenService")


local InviteCooldowns = {}

---[REMOTE FUNCTIONS]---
local GetRoomDataFunction = ReplicatedStorage.Comms.Lobby:WaitForChild("GetRoom")
local GetPlayersBusyFunction = ReplicatedStorage.Comms.Lobby:WaitForChild("GetPlayersBusy")
local InvitePlayerFunction = ReplicatedStorage.Comms.Lobby:WaitForChild("InvitePlayer")
---[REMOTE EVENTS]---
local JoinedRoomEvent = ReplicatedStorage.Comms.Lobby:WaitForChild("JoinedRoom")


local CurrentBlur 

Component.Instance = PlayerGui:WaitForChild("Room"):WaitForChild("ServerList")
Component.ScrollingFrame = Component.Instance:FindFirstChildWhichIsA("ScrollingFrame")
Component.PlayerTemplate = Component.ScrollingFrame:WaitForChild("PlayerTemplate")
Component.RoomData = nil




type ChooseComponentData = {
    type: string,
    delay: number?,
    content: string,
    confirmText: string?,
    cancelText: string?,
    confirmCallback: (() -> ())?,
    cancelCallback: (() -> ())?,
}

local PlayerGuiVisibilities = {}
local ButtonConnections = {}
local EventConnections = {}


local function alert(data: ChooseComponentData)
    ChooseComponent:Show(data)
end


function GetCurrentRoom()
    local CurrentRoomId = LocalPlayer:GetAttribute("CurrentRoomId")


    if not CurrentRoomId then return false end

    local RoomData = GetRoomDataFunction:InvokeServer(CurrentRoomId)
    if not RoomData then return false end

    
    return RoomData
end

function PlayerIsInRoom(player, roomData)
    print(roomData)
    for _, playerId in ipairs(roomData.playerUserIds) do
        if playerId == player.UserId then
            return true
        end
    end

    return false
end

function HandleOpenEffect(component)
    local Lighting = game:GetService("Lighting")
    local Blur = Lighting:FindFirstChildWhichIsA("BlurEffect")

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

function HandleCloseEffect(component)
   
    if CurrentBlur.Instance then
        local Tween = TweenService:Create(CurrentBlur.Instance, TweenInfo.new(0.5), {Size = 0})
        Tween:Play()
    end
end


function HideAllUIs()
    for _, Gui in ipairs(PlayerGui:GetDescendants()) do
        if Gui ~= Component.Instance and not Gui:IsDescendantOf(Component.Instance) and Gui:IsA("GuiObject") and Gui.Visible then
            PlayerGuiVisibilities[Gui] = true
            Gui.Visible = false
        end
    end
end

function RestoreAllUIs()
    for Gui, WasEnabled in pairs(PlayerGuiVisibilities) do
        if WasEnabled then
            Gui.Visible = true
        end
    end
    PlayerGuiVisibilities = {}
end

function Component:BindEvents()
    EventConnections[JoinedRoomEvent] = JoinedRoomEvent:Connect(function(playerUserId, roomData)
        self.RoomData = roomData
    end)
end

function Component:BindButtons()
    local BackButton = Component.Instance:WaitForChild("Back")
    local PlayerEntries = Component.ScrollingFrame:GetChildren()

    for i,v in pairs(PlayerEntries) do
        if v:IsA("ImageLabel") and v.Name ~= "PlayerTemplate" then
            local Player = Players:GetPlayerByUserId(tonumber(v.Name))
            local InviteButton = v:FindFirstChild("Invite")
            local InviteLabel = v:FindFirstChild("Invited")
            if Player and InviteButton then
                ButtonConnections[InviteButton] = InviteButton.Activated:Connect(function()
                    print("invite " .. Player.Name)
                    if InviteCooldowns[Player.UserId] and tick() - InviteCooldowns[Player.UserId] < 5 then
                        return
                    end
                    InviteCooldowns[Player.UserId] = tick()
                    InviteButton.Visible = false
                    InviteLabel.Visible = true
                    print(Player.Name, Player.UserId, InvitePlayerFunction)
                    local inviteId = InvitePlayerFunction:InvokeServer(Player.UserId)
                    print("inviteId")
                    task.delay(10, function()
                        InviteButton.Visible = true
                        InviteLabel.Visible = false
                    end)                    
                end)
            end
        end
    end
    if BackButton then
        ButtonConnections[BackButton] = BackButton.Activated:Once(function()
            print("back button")
            Component.Instance.Visible = false
            HandleCloseEffect()
            RestoreAllUIs()
            self:UnbindButtons() 
        end)
    end
end

function Component:UnbindButtons()
    for Button, Connection in pairs(ButtonConnections) do
        if Connection.Connected then
            Connection:Disconnect()
            Connection = nil
        end
    end
    ButtonConnections = {}
end

function Component:LoadPlayers()
    return Promise.new(function(resolve, reject)

        local playerList = Players:GetPlayers()
        
        self.RoomData = GetCurrentRoom()

        for i,v in pairs(self.ScrollingFrame:GetChildren()) do
            if v:IsA("ImageLabel") then
                if v.Name ~= "PlayerTemplate" then
                    v:Destroy()
                else
                    v.Visible = false
                end
            end  
        end

        if #playerList > 0 then
            for i, player in ipairs(playerList) do
                if player.UserId == LocalPlayer.UserId then continue end
                if PlayerIsInRoom(player, self.RoomData) then continue end

                local playerEntry = Component.PlayerTemplate:Clone()
                playerEntry.Parent = Component.ScrollingFrame
                playerEntry.Name = player.UserId
                playerEntry.PlayerName.Text = player.Name
                playerEntry.Visible = true
            end
            resolve()
        else
            reject("No players found")
        end
    end)
end

function Component:Render()
    self:LoadPlayers():andThen(function()
        ToggleLoading:Toggle(false)
        Component.Instance.Visible = true
        HandleOpenEffect()
        HideAllUIs()
        self:BindButtons()
    end):catch(function(error)
        alert({
            type = "Center",
            content = "Failed to server list",
            confirmText = "Retry",
            confirmCallback = function()
                self:Render()
            end,
        })
        warn("Failed to load players: " .. tostring(error))
    end)
    JoinedRoomEvent.OnClientEvent:Connect(function(playerUserId, roomData)
        self:LoadPlayers()
    end)
end

return Component