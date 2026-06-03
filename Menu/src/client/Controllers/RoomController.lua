local RoomController = {}
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Cameras = workspace:WaitForChild("Cameras")
local PlayerGui = game.Players.LocalPlayer:WaitForChild("PlayerGui")
local Player = game.Players.LocalPlayer

local LeaveRemoteFunction = ReplicatedStorage.Comms.Lobby:WaitForChild("LeaveRoom")
local ChangeStatusFunction = ReplicatedStorage.Comms.Lobby:WaitForChild("ChangePlayerStatus")
local GetRoomDataFunction = ReplicatedStorage.Comms.Lobby:WaitForChild("GetRoom")
local StartGameFunction = ReplicatedStorage.Comms.Lobby:WaitForChild("StartGame")
local JoinedRoomEvent = ReplicatedStorage.Comms.Lobby:WaitForChild("JoinedRoom")
local LeftRoomEvent = ReplicatedStorage.Comms.Lobby:WaitForChild("LeftRoom")
local StatusChangedEvent = ReplicatedStorage.Comms.Lobby:WaitForChild("PlayerStatusChanged")
local StartGameEvent = ReplicatedStorage.Comms.Lobby:WaitForChild("GameStarted")


local PlayersStatusCache = {}  

local MenuController

local ToggleLoading = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SharedModules"):WaitForChild("ToggleLoading"))

local Promise = require(ReplicatedStorage:WaitForChild("ExternalPackages"):WaitForChild("promise"))

local function CreateLocalDummyFromUserId(userId: number)
	local success, characterModel = pcall(function()
        if userId < 0 then 
            return game:GetService("Players"):CreateHumanoidModelFromUserIdAsync(46871391) 
        end
		return game:GetService("Players"):CreateHumanoidModelFromUserIdAsync(userId)
	end)

	if not success then
		warn("Error on CreateLocalDummyFromUserId:", characterModel)
		return nil
	end

	characterModel.Name = "LocalAppearanceDummy"
	characterModel.Parent = workspace

	local humanoid = characterModel:FindFirstChildOfClass("Humanoid")

	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
	end

	characterModel:PivotTo(CFrame.new(0, 5, 0))

	return characterModel
end

local function dictSize(tbl)
    local count = 0
    for _, _ in pairs(tbl) do
        count += 1
    end
    return count
end

local function getAllPlayersWithStatus(status)
    local count = 0
    for i,v in pairs(PlayersStatusCache) do
        if v == status then
            count += 1
        end
    end
    return count
end

local function getPositionAvailable()
    local PlayersInRoom = workspace:FindFirstChild("PlayersInRoom")

    for i,v in pairs(PlayersInRoom:GetChildren()) do
        if not v:GetAttribute("Occupied") then
            return v
        end
    end
end

local function getCharacterByUserId(userId)
    local playersInRoom = workspace:FindFirstChild("PlayersInRoom")

    if not playersInRoom then
        return nil
    end

    for _, instance in ipairs(playersInRoom:GetChildren()) do
        if instance:IsA("Model") and instance:GetAttribute("UserId") == userId then
            return instance
        end
    end

    return nil
end

local function releasePositionForUserId(userId)
    local playersInRoom = workspace:FindFirstChild("PlayersInRoom")

    if not playersInRoom then
        return
    end

    for _, instance in ipairs(playersInRoom:GetChildren()) do
        if instance:IsA("Part") and instance:GetAttribute("UserId") == userId then
            instance:SetAttribute("Occupied", false)
            instance:SetAttribute("UserId", nil)
        end
    end
end

local function toggleTagStatus(characterModel, status)
    local tag = characterModel:FindFirstChild("Head"):FindFirstChild("Tag")
    if tag then
        local textLabel = tag:FindFirstChild("Ready")

        if textLabel then
            if status == "Ready" then
                textLabel.Text = "Ready"
                textLabel.TextColor3 = Color3.fromRGB(0, 109, 16) 
            else
                textLabel.Text = "Not Ready"
                textLabel.TextColor3 = Color3.fromRGB(109, 0, 0) 
            end
        end
    end
end

function RoomController:UpdateStartButton()
    local roomData = self:GetRoomData()
    if roomData then
        if roomData.ownerUserId == game.Players.LocalPlayer.UserId then
            local RoomGui = PlayerGui:WaitForChild("Room")
            local StartButton = RoomGui:FindFirstChild("Start", true)
            if StartButton then
                StartButton.Visible = true
            end
        end
    end
end

function RoomController:GetRoomData()
    local currentRoomId = Player:GetAttribute("CurrentRoomId")

    if not currentRoomId then
        return nil
    end

    local roomData = GetRoomDataFunction:InvokeServer(currentRoomId)

    if roomData then
        return roomData
    else
        warn("Failed to fetch room data for roomId:", currentRoomId)
        return nil
    end
end

function RoomController:IsRoomReady()
    local readyStatusCount = getAllPlayersWithStatus("Ready")
    local totalPlayers = dictSize(PlayersStatusCache)

    if totalPlayers > 0 and readyStatusCount == totalPlayers then
        return true
    end

    return false
end

function RoomController:StartGame()

end

function RoomController:ToggleStatus(UserId)
    return Promise.new(function(resolve, reject)
        for i,v in pairs(workspace:FindFirstChild("PlayersInRoom"):GetChildren()) do
            if v:GetAttribute("UserId") == UserId and v:IsA("Model") then
                local currentStatus = v:GetAttribute("Status") or "NotReady"
                local Tag = v:FindFirstChild("Head"):FindFirstChild("Tag")
                local newStatus
                if currentStatus == "NotReady" then
                    newStatus = "Ready"
                else
                    newStatus = "NotReady"
                end
                v:SetAttribute("Status", newStatus)
                toggleTagStatus(v, newStatus)

                if v:GetAttribute("UserId") == Player.UserId then
                    local RoomGui = PlayerGui:WaitForChild("Room")
                    local ReadyButton = RoomGui:FindFirstChild("Ready", true)
                    if ReadyButton then
                        if newStatus == "Ready" then
                            ReadyButton.TextLabel.TextColor3 = Color3.fromRGB(0, 109, 16)
                            ReadyButton.TextLabel.Text = "Ready"
                        else
                            ReadyButton.TextLabel.TextColor3 = Color3.fromRGB(109, 0, 0)
                            ReadyButton.TextLabel.Text = "Not Ready"
                        end
                    end
                end
                local response = ChangeStatusFunction:InvokeServer({
                    userId = UserId,
                    roomId = Player:GetAttribute("CurrentRoomId"),
                    newStatus = newStatus
                })

                if response then
                    PlayersStatusCache[UserId] = newStatus
                    resolve()
                else
                    reject("Failed to change status on server")
                end
            end
        end
    end)
end

function RoomController:ObserveStatusChanges()
    if not self.statusChangedConnection then
        self.statusChangedConnection = StatusChangedEvent.OnClientEvent:Connect(function(roomId, playerUserId, newStatus)
            if Player:GetAttribute("CurrentRoomId") ~= roomId then
                return
            end

            for i,v in pairs(workspace:FindFirstChild("PlayersInRoom"):GetChildren()) do
                if v:GetAttribute("UserId") == playerUserId and v:IsA("Model") then
                    v:SetAttribute("Status", newStatus)
                    toggleTagStatus(v, newStatus)
                    PlayersStatusCache[playerUserId] = newStatus
                end
            end

            local readyCount = getAllPlayersWithStatus("Ready")
            local isRoomReady = self:IsRoomReady()

            if isRoomReady then
                self:UpdateStartButton()
            end
        end)
    end

    if not self.startedGame then
        self.startedGame = StartGameEvent.OnClientEvent:Connect(function(roomId)
            local PlrGuiBlackList = {
                "SharedGuis"
            }

            if Player:GetAttribute("CurrentRoomId") ~= roomId then
                return
            end

            ToggleLoading:Toggle(true)

            for i,v in pairs(PlayerGui:GetChildren()) do
                if not table.find(PlrGuiBlackList, v.Name) and v:IsA("ScreenGui") then
                    v.Enabled = false
                end
            end
        end)
    end
end

function RoomController:UpdateCharacters(playersIds)
    for i,v in pairs(workspace:FindFirstChild("PlayersInRoom"):GetChildren()) do
        if v:GetAttribute("UserId") and not table.find(playersIds, v:GetAttribute("UserId")) then
            local userId = v:GetAttribute("UserId")
            releasePositionForUserId(userId)
            PlayersStatusCache[userId] = nil
            v:Destroy()
        end
    end
end

function RoomController:AddCharacter(userId)
    if getCharacterByUserId(userId) then
        return
    end

    local success, dummyOrError = pcall(CreateLocalDummyFromUserId, userId)

    if not success or not dummyOrError then
        warn("Failed to create dummy for userId:", dummyOrError)
        return
    end

    local dummy = dummyOrError
    local playersInRoom = workspace:FindFirstChild("PlayersInRoom")
    local partPosition = getPositionAvailable()

    if not playersInRoom or not partPosition then
        warn("No available position for dummy of userId:", userId)
        dummy:Destroy()
        return
    end

    local tagClone = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("UI"):WaitForChild("Tag"):Clone()
    dummy.Parent = playersInRoom
    dummy:PivotTo(partPosition.CFrame)
    dummy:SetAttribute("UserId", userId)
    dummy:SetAttribute("Status", "NotReady")
    toggleTagStatus(dummy, "NotReady")
    PlayersStatusCache[userId] = "NotReady"
    tagClone.Parent = dummy:FindFirstChild("Head")
    local username = game.Players:GetNameFromUserId(userId) or "Unknown"
    tagClone.PlayerName.Text = "@"..username
    partPosition:SetAttribute("Occupied", true)
    partPosition:SetAttribute("UserId", userId)
end

function RoomController:RemoveCharacter(userId)
    local character = getCharacterByUserId(userId)

    releasePositionForUserId(userId)
    PlayersStatusCache[userId] = nil

    if character then
        character:Destroy()
    end
end

function RoomController:LoadCharacters(playerIds)
    for i,v in pairs(playerIds) do
        self:AddCharacter(v)
    end
end

function RoomController:ObserveRoomMembershipChanges()
    if self.joinedRoomConnection or self.leftRoomConnection then
        return
    end

    self.joinedRoomConnection = JoinedRoomEvent.OnClientEvent:Connect(function(playerUserId, roomData)
        if not roomData or Player:GetAttribute("CurrentRoomId") ~= roomData.id then
            return
        end

        self:AddCharacter(playerUserId)
    end)

    self.leftRoomConnection = LeftRoomEvent.OnClientEvent:Connect(function(playerUserId, roomData)
        if not roomData or Player:GetAttribute("CurrentRoomId") ~= roomData.id then
            return
        end

        self:RemoveCharacter(playerUserId)
    end)
end

function RoomController:ClearCharacters()

    return Promise.new(function(resolve)
        local PlayersInRoom = workspace:FindFirstChild("PlayersInRoom")
        for i,v in pairs(PlayersInRoom:GetChildren()) do
            if v.Name == "LocalAppearanceDummy" then
                v:Destroy()
                v:SetAttribute("Occupied", false)
            end
            if v:IsA("Part") then
                v:SetAttribute("Occupied", false)
                v:SetAttribute("UserId", nil)
            end
        end
        PlayersStatusCache = {}
        resolve()
    end)
end

function RoomController:SetupCamera()
    local RoomCamera = Cameras:FindFirstChild("Room")
    if RoomCamera then
        workspace.CurrentCamera.CFrame = RoomCamera.CFrame
    end
end

function RoomController:RenderAndBindButtons(roomData)
    local RoomGui = PlayerGui:WaitForChild("Room")
    local LeaveOrDisband = RoomGui:FindFirstChild("LeaveOrDisband", true)
    local Ready = RoomGui:FindFirstChild("Ready", true)
    local StartButton = RoomGui:FindFirstChild("Start", true)
    local IsOwner = roomData.ownerUserId == game.Players.LocalPlayer.UserId

    if IsOwner then
        if LeaveOrDisband then
            LeaveOrDisband.TextLabel.Text = "Disband"
        end
    else
        if LeaveOrDisband then
            LeaveOrDisband.TextLabel.Text = "Leave"
        end
    end

    if LeaveOrDisband then
        LeaveOrDisband.Activated:Once(function()
            local Response = LeaveRemoteFunction:InvokeServer({
                userId = game.Players.LocalPlayer.UserId,
                roomId = roomData.id,
            })
            if Response then
                workspace.CurrentCamera.CFrame = Cameras.Menu.CFrame
                RoomGui.Frame.Visible = false
                ToggleLoading:Toggle(true)
                self:ClearCharacters():andThen(function()
                    ToggleLoading:Toggle(false)
                    MenuController:BindMenuButtons()
                    Player:SetAttribute("CurrentRoomId", nil)
                end)

                if self.statusChangedConnection then
                    self.statusChangedConnection:Disconnect()
                    self.statusChangedConnection = nil
                end

                if self.readyConnection then
                    self.readyConnection:Disconnect()
                    self.readyConnection = nil
                end

                if self.joinedRoomConnection then
                    self.joinedRoomConnection:Disconnect()
                    self.joinedRoomConnection = nil
                end

                if self.leftRoomConnection then
                    self.leftRoomConnection:Disconnect()
                    self.leftRoomConnection = nil
                end

                if self.startedGame then
                    self.startedGame:Disconnect()
                    self.startedGame = nil
                end
            end
        end)
    end

    if Ready then
        Ready.Parent.Visible = true
        Ready.TextLabel.TextColor3 = Color3.fromRGB(109,0,0)
        Ready.TextLabel.Text = "Not Ready"
        self.readyConnection = Ready.Activated:Connect(function()
            local RoomGui = PlayerGui:WaitForChild("Room")

            ToggleLoading:Toggle(true)
            self:ToggleStatus(game.Players.LocalPlayer.UserId):andThen(function()
                local isRoomReady = self:IsRoomReady()

                if isRoomReady then
                    self:UpdateStartButton()
                end
                ToggleLoading:Toggle(false)
            end)
        end)
    end

    if StartButton then
        StartButton.Activated:Once(function()
            local roomData = self:GetRoomData()
            if roomData and roomData.id == Player:GetAttribute("CurrentRoomId") then
                local response = StartGameFunction:InvokeServer(roomData.id)

                if not response then
                    warn("Failed to start game on server")
                end
            end
        end)
    end        
end

function RoomController:LoadRoom(RoomData)
    return Promise.new(function(resolve, reject)
        Player:SetAttribute("CurrentRoomId", RoomData.id)
        self:ObserveStatusChanges()
        self:ObserveRoomMembershipChanges()
        self:SetupCamera()
        self:RenderAndBindButtons(RoomData)
        self:LoadCharacters(RoomData.playerUserIds)
        resolve()
    end)
end



function RoomController:Start()
    MenuController = self.GetController("MenuController")
end

return RoomController