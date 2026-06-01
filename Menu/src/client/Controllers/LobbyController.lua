local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

local LobbyController = {}
local RoomOptionsController

local function findFirstGuiObjectByName(instance, name)
    if instance.Name == name then
        return instance
    end

    for _, descendant in ipairs(instance:GetDescendants()) do
        if descendant.Name == name and descendant:IsA("GuiObject") then
            return descendant
        end
    end

    return nil
end

local function setTextIfPresent(container, candidateNames, text)
    for _, candidateName in ipairs(candidateNames) do
        local guiObject = findFirstGuiObjectByName(container, candidateName)

        if guiObject and guiObject:IsA("TextLabel") or guiObject and guiObject:IsA("TextButton") then
            guiObject.Text = text
            return true
        end
    end

    return false
end

local function getRoomOccupancyText(roomData)
    local currentPlayers = #(roomData.playerUserIds or {})
    return string.format("%d/%d", currentPlayers, roomData.maxPlayers)
end

function LobbyController:GetJoinRoomFrame()
    local hud = PlayerGui:WaitForChild("Hud")
    return hud:WaitForChild("JoinRoom")
end

function LobbyController:GetRoomSlotTemplate()
    local joinRoom = self:GetJoinRoomFrame()
    local frame = joinRoom:WaitForChild("Frame")
    local scrollingFrame = frame:WaitForChild("ScrollingFrame")

    return scrollingFrame, scrollingFrame:WaitForChild("RoomSlotTemplate")
end

function LobbyController:SetupRoomRemotes()
    if self.roomUpdatesEvent and self.listRoomsFunction then
        return
    end

    local commsFolder = ReplicatedStorage:WaitForChild("Comms")
    local lobbyFolder = commsFolder:WaitForChild("Lobby")

    self.listRoomsFunction = lobbyFolder:WaitForChild("ListRooms")
    self.roomUpdatesEvent = lobbyFolder:WaitForChild("RoomUpdates")
end

function LobbyController:ClearRenderedRooms()
    local scrollingFrame, roomSlotTemplate = self:GetRoomSlotTemplate()

    for _, child in ipairs(scrollingFrame:GetChildren()) do
        if child ~= roomSlotTemplate and child:GetAttribute("RoomId") then
            child:Destroy()
        end
    end

    self.roomSlotsById = {}
end

function LobbyController:BindJoinButton(roomSlot, roomData)
    local joinButton = findFirstGuiObjectByName(roomSlot, "Join")

    if joinButton and joinButton:IsA("GuiButton") and not joinButton:GetAttribute("IsBound") then
        joinButton:SetAttribute("IsBound", true)
        joinButton.Activated:Connect(function()
            warn(string.format("Join room flow not implemented yet for room %s", roomData.id))
        end)
    end
end

function LobbyController:ApplyRoomDataToSlot(roomSlot, roomData)
    roomSlot.Name = string.format("Room_%s", roomData.id)
    roomSlot:SetAttribute("RoomId", roomData.id)
    roomSlot.LayoutOrder = roomData.createdAt or 0
    roomSlot.Visible = true

    setTextIfPresent(roomSlot, { "RoomName", "Name", "Title" }, roomData.name)
    setTextIfPresent(roomSlot, { "OwnerName", "Owner", "HostName", "Host" }, roomData.ownerName)
    setTextIfPresent(roomSlot, { "PlayerCount", "Players", "Slots", "Capacity" }, getRoomOccupancyText(roomData))
    setTextIfPresent(roomSlot, { "Privacy", "Status", "RoomType" }, roomData.isPrivate and "Private" or "Public")

    if roomData.isPrivate then
        setTextIfPresent(roomSlot, { "AccessCode", "Code", "RoomCode" }, roomData.accessCode or "LOCKED")
    else
        setTextIfPresent(roomSlot, { "AccessCode", "Code", "RoomCode" }, "PUBLIC")
    end

    self:BindJoinButton(roomSlot, roomData)
end

function LobbyController:RenderRoom(roomData)
    local _, roomSlotTemplate = self:GetRoomSlotTemplate()

    if not self.roomSlotsById then
        self.roomSlotsById = {}
    end

    local roomSlot = self.roomSlotsById[roomData.id]

    if not roomSlot then
        roomSlot = roomSlotTemplate:Clone()
        roomSlot.Parent = roomSlotTemplate.Parent
        self.roomSlotsById[roomData.id] = roomSlot
    end

    self:ApplyRoomDataToSlot(roomSlot, roomData)
end

function LobbyController:RemoveRoom(roomId)
    if not self.roomSlotsById then
        return
    end

    local roomSlot = self.roomSlotsById[roomId]

    if roomSlot then
        roomSlot:Destroy()
        self.roomSlotsById[roomId] = nil
    end
end

function LobbyController:RenderRooms(roomList)
    local _, roomSlotTemplate = self:GetRoomSlotTemplate()
    roomSlotTemplate.Visible = false

    self:ClearRenderedRooms()

    for _, roomData in ipairs(roomList) do
        self:RenderRoom(roomData)
    end
end

function LobbyController:ObserveRoomUpdates()
    if self.roomUpdatesConnection then
        return
    end

    self.roomUpdatesConnection = self.roomUpdatesEvent.OnClientEvent:Connect(function(action, roomData)
        if action == "deleted" then
            self:RemoveRoom(roomData.id)
            return
        end

        self:RenderRoom(roomData)
    end)
end

function LobbyController:FetchAndRenderRooms()
    self:SetupRoomRemotes()
    self:ObserveRoomUpdates()

    local roomList = self.listRoomsFunction:InvokeServer(false)
    self:RenderRooms(roomList)
end


function LobbyController:BindLobbyButtons()
    local JoinRoom = self:GetJoinRoomFrame()

    local BackButton = JoinRoom:WaitForChild("Back")

    self:FetchAndRenderRooms()

    BackButton.MouseButton1Click:Once(function()
        JoinRoom.Visible = false
        local Hud = PlayerGui:WaitForChild("Hud")
        local RoomOptions = Hud:WaitForChild("RoomOptions")
        RoomOptions.Visible = true
        RoomOptionsController:BindOptionsButtons()
    end)    
end

function LobbyController:Start()
    RoomOptionsController = self.GetController("RoomOptionsController")
    self.roomSlotsById = {}
end

return LobbyController