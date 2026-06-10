local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")
local ServerScriptService = game:GetService("ServerScriptService")

local SharedModules = ServerScriptService:WaitForChild("Server"):WaitForChild("SharedModules")
local SafeTeleport = require(SharedModules.SafeTeleport)

local GAME_PLACE_ID = 134969655606525

local DEFAULT_MAX_PLAYERS = 4
local MIN_MAX_PLAYERS = 1
local MAX_MAX_PLAYERS = 8
local COMMS_FOLDER_NAME = "Comms"
local LOBBY_COMMS_FOLDER_NAME = "Lobby"
local CREATE_ROOM_FUNCTION_NAME = "CreateRoom"
local LIST_ROOMS_FUNCTION_NAME = "ListRooms"
local ROOM_UPDATES_EVENT_NAME = "RoomUpdates"
local GET_ROOM_FUNCTION_NAME = "GetRoom"
local LEAVE_ROOM_FUNCTION_NAME = "LeaveRoom"
local JOIN_ROOM_FUNCTION_NAME = "JoinRoom"
local CHANGE_PLAYER_STATUS_FUNCTION_NAME = "ChangePlayerStatus"
local PLAYER_STATUS_CHANGED_EVENT_NAME = "PlayerStatusChanged"
local JOINED_ROOM_EVENT_NAME = "JoinedRoom"
local LEFT_ROOM_EVENT_NAME = "LeftRoom"
local START_GAME_EVENT_NAME = "GameStarted"
local START_GAME_FUNCTION_NAME = "StartGame"
local GET_PLAYERS_BUSY_FUNCTION_NAME = "GetPlayersBusy"
local INVITE_PLAYER_FUNCTION_NAME = "InvitePlayer"
local PLAYER_INVITED_EVENT_NAME = "PlayerInvited"
local ACCEPT_INVITE_FUNCTION_NAME = "AcceptInvite"

local LobbyService = {}

local Invites = {}


local function ensureServiceState(self)
    if not self.roomsById then
        self.roomsById = {}
    end

    if not self.roomIdsByOwner then
        self.roomIdsByOwner = {}
    end
end

local function cloneArray(values)
    local clonedValues = {}

    for index, value in ipairs(values) do
        clonedValues[index] = value
    end

    return clonedValues
end

local function trimString(value)
    return string.gsub(value, "^%s*(.-)%s*$", "%1")
end

local function buildRoomSnapshot(room)
    return {
        id = room.id,
        ownerUserId = room.ownerUserId,
        ownerName = room.ownerName,
        name = room.name,
        maxPlayers = room.maxPlayers,
        roomType = room.roomType,
        isPrivate = room.isPrivate,
        accessCode = room.accessCode,
        playerUserIds = cloneArray(room.playerUserIds),
        createdAt = room.createdAt,
        updatedAt = room.updatedAt,
        isDisband = room.isDisband or false,
    }
end

local function convertUserIdTableToPlayerTable(userIds)
    local players = {}

    for _, userId in ipairs(userIds) do
        local player = Players:GetPlayerByUserId(userId)

        if player then
            table.insert(players, player)
        end
    end

    return players
end

local function getPlayersInRoom(room)
    local playersInRoom = {}

    if not room then
        return playersInRoom
    end

    for _, userId in ipairs(room.playerUserIds or {}) do
        local player = Players:GetPlayerByUserId(userId)

        if player then
            table.insert(playersInRoom, player)
        end
    end

    return playersInRoom
end

function LobbyService:Init()
    ensureServiceState(self)
end

function LobbyService:Start()
    self:SetupRemotes()

    Players.PlayerRemoving:Connect(function(player)
        self:HandlePlayerRemoving(player)
    end)
end

function LobbyService:SetupRemotes()
    local commsFolder = ReplicatedStorage:FindFirstChild(COMMS_FOLDER_NAME)

    if not commsFolder then
        commsFolder = Instance.new("Folder")
        commsFolder.Name = COMMS_FOLDER_NAME
        commsFolder.Parent = ReplicatedStorage
    end

    local lobbyFolder = commsFolder:FindFirstChild(LOBBY_COMMS_FOLDER_NAME)

    if not lobbyFolder then
        lobbyFolder = Instance.new("Folder")
        lobbyFolder.Name = LOBBY_COMMS_FOLDER_NAME
        lobbyFolder.Parent = commsFolder
    end

    local createRoomFunction = lobbyFolder:FindFirstChild(CREATE_ROOM_FUNCTION_NAME)

    if not createRoomFunction then
        createRoomFunction = Instance.new("RemoteFunction")
        createRoomFunction.Name = CREATE_ROOM_FUNCTION_NAME
        createRoomFunction.Parent = lobbyFolder
    end

    local listRoomsFunction = lobbyFolder:FindFirstChild(LIST_ROOMS_FUNCTION_NAME)

    if not listRoomsFunction then
        listRoomsFunction = Instance.new("RemoteFunction")
        listRoomsFunction.Name = LIST_ROOMS_FUNCTION_NAME
        listRoomsFunction.Parent = lobbyFolder
    end

    local getRoomFunction = lobbyFolder:FindFirstChild(GET_ROOM_FUNCTION_NAME)

    if not getRoomFunction then
        getRoomFunction = Instance.new("RemoteFunction")
        getRoomFunction.Name = GET_ROOM_FUNCTION_NAME
        getRoomFunction.Parent = lobbyFolder
    end

    local getPlayersBusyFunction = lobbyFolder:FindFirstChild(GET_PLAYERS_BUSY_FUNCTION_NAME)

    if not getPlayersBusyFunction then
        getPlayersBusyFunction = Instance.new("RemoteFunction")
        getPlayersBusyFunction.Name = GET_PLAYERS_BUSY_FUNCTION_NAME
        getPlayersBusyFunction.Parent = lobbyFolder
    end

    local joinRoomFunction = lobbyFolder:FindFirstChild(JOIN_ROOM_FUNCTION_NAME)

    if not joinRoomFunction then
        joinRoomFunction = Instance.new("RemoteFunction")
        joinRoomFunction.Name = JOIN_ROOM_FUNCTION_NAME
        joinRoomFunction.Parent = lobbyFolder
    end

    local leaveRoomFunction = lobbyFolder:FindFirstChild(LEAVE_ROOM_FUNCTION_NAME)

    if not leaveRoomFunction then
        leaveRoomFunction = Instance.new("RemoteFunction")
        leaveRoomFunction.Name = LEAVE_ROOM_FUNCTION_NAME
        leaveRoomFunction.Parent = lobbyFolder
    end

    local changePlayerStatusFunction = lobbyFolder:FindFirstChild(CHANGE_PLAYER_STATUS_FUNCTION_NAME)

    if not changePlayerStatusFunction then
        changePlayerStatusFunction = Instance.new("RemoteFunction")
        changePlayerStatusFunction.Name = CHANGE_PLAYER_STATUS_FUNCTION_NAME
        changePlayerStatusFunction.Parent = lobbyFolder
    end

    local invitePlayerFunction = lobbyFolder:FindFirstChild(INVITE_PLAYER_FUNCTION_NAME)

    if not invitePlayerFunction then
        invitePlayerFunction = Instance.new("RemoteFunction")
        invitePlayerFunction.Name = INVITE_PLAYER_FUNCTION_NAME
        invitePlayerFunction.Parent = lobbyFolder
    end

    local playerInvitedEvent = lobbyFolder:FindFirstChild(PLAYER_INVITED_EVENT_NAME)

    if not playerInvitedEvent then
        playerInvitedEvent = Instance.new("RemoteEvent")
        playerInvitedEvent.Name = PLAYER_INVITED_EVENT_NAME
        playerInvitedEvent.Parent = lobbyFolder
    end

    local acceptInviteFunction = lobbyFolder:FindFirstChild(ACCEPT_INVITE_FUNCTION_NAME)

    if not acceptInviteFunction then
        acceptInviteFunction = Instance.new("RemoteFunction")
        acceptInviteFunction.Name = ACCEPT_INVITE_FUNCTION_NAME
        acceptInviteFunction.Parent = lobbyFolder
    end

    local startGameFunction = lobbyFolder:FindFirstChild(START_GAME_FUNCTION_NAME)

    if not startGameFunction then
        startGameFunction = Instance.new("RemoteFunction")
        startGameFunction.Name = START_GAME_FUNCTION_NAME
        startGameFunction.Parent = lobbyFolder
    end

    local roomUpdatesEvent = lobbyFolder:FindFirstChild(ROOM_UPDATES_EVENT_NAME)

    if not roomUpdatesEvent then
        roomUpdatesEvent = Instance.new("RemoteEvent")
        roomUpdatesEvent.Name = ROOM_UPDATES_EVENT_NAME
        roomUpdatesEvent.Parent = lobbyFolder
    end

    local joinedRoomEvent = lobbyFolder:FindFirstChild(JOINED_ROOM_EVENT_NAME)

    if not joinedRoomEvent then
        joinedRoomEvent = Instance.new("RemoteEvent")
        joinedRoomEvent.Name = JOINED_ROOM_EVENT_NAME
        joinedRoomEvent.Parent = lobbyFolder
    end

    local leftRoomEvent = lobbyFolder:FindFirstChild(LEFT_ROOM_EVENT_NAME)

    if not leftRoomEvent then
        leftRoomEvent = Instance.new("RemoteEvent")
        leftRoomEvent.Name = LEFT_ROOM_EVENT_NAME
        leftRoomEvent.Parent = lobbyFolder
    end

    local playerStatusChangedEvent = lobbyFolder:FindFirstChild(PLAYER_STATUS_CHANGED_EVENT_NAME)

    if not playerStatusChangedEvent then
        playerStatusChangedEvent = Instance.new("RemoteEvent")
        playerStatusChangedEvent.Name = PLAYER_STATUS_CHANGED_EVENT_NAME
        playerStatusChangedEvent.Parent = lobbyFolder
    end

    local startGameEvent = lobbyFolder:FindFirstChild(START_GAME_EVENT_NAME)

    if not startGameEvent then
        startGameEvent = Instance.new("RemoteEvent")
        startGameEvent.Name = START_GAME_EVENT_NAME
        startGameEvent.Parent = lobbyFolder
    end

    startGameFunction.OnServerInvoke = function(player, roomId)

        local room = self.roomsById[roomId]
        local playersInRoom = getPlayersInRoom(room)

        if not room then
            return false, string.format("Room %s was not found", tostring(roomId))
        end

        if player.UserId ~= room.ownerUserId then
            return false, "Only the room owner can start the game"
        end
        
        local success, result, err = pcall(function()
        	return SafeTeleport:ReserveServerAndTeleport(GAME_PLACE_ID, playersInRoom)
        end)
        
        if not success then
        	warn("Teleport crashed:", tostring(result))
        	return false
        end
        
        if result == false then
        	warn("Teleport failed:", tostring(err))
        	return false
        end
        
        print("Teleport started successfully:", result)

        self:BroadcastStartGame(roomId)
        return true
    end

    changePlayerStatusFunction.OnServerInvoke = function(player, data)
        local roomId = data.roomId
        local userId = data.userId
        local newStatus = data.newStatus

        local room = self.roomsById[roomId]

        if not room then
            return false, string.format("Room %s was not found", tostring(roomId))
        end

        if userId ~= player.UserId then
            return false, "userId must match the invoking player's UserId"
        end

        if not table.find(room.playerUserIds, userId) then
            return false, string.format("User %s is not in room %s", tostring(userId), tostring(roomId))
        end

        room.playerStatuses[userId] = newStatus
        self:BroadcastPlayerStatusChange(roomId, userId, newStatus)

        return true
    end

    invitePlayerFunction.OnServerInvoke = function(player, targetUserId)
    	local roomId = self:GetPlayerRoomId(player.UserId)
    	if not roomId then
    		return false, "Player is not in a room"
    	end

    	local room = self.roomsById[roomId]
    	if not room then
    		return false, "Room not found"
    	end

    	local targetPlayer = Players:GetPlayerByUserId(targetUserId)
    	if not targetPlayer then
    		return false, "Target player not found"
    	end

    	local invite = self:GenerateInvite(player, targetPlayer)
    	if not invite then
    		return false, "Failed to generate invite"
    	end

        local inviteData = {
            id = invite.id,
            inviterUserId = invite.inviterUserId,
            inviterName = player.Name,
            inviteeUserId = invite.inviteeUserId,
            expiresAt = invite.expiresAt,
            roomId = roomId,
        }

        Invites[invite.id] = inviteData

    	playerInvitedEvent:FireClient(targetPlayer, inviteData)

    	return true
    end

    acceptInviteFunction.OnServerInvoke = function(player, inviteId)

    	local invite = Invites[inviteId]
    	if not invite then
    		return false, "Invite not found or expired"
    	end

    	if invite.inviteeUserId ~= player.UserId then
    		return false, "This invite is not for the invoking player"
    	end

    	local roomId = invite.roomId
    	local room = self.roomsById[roomId]
    	if not room then
    		return false, "Room not found"
    	end

    	local success, result = self:AddPlayerToRoom(roomId, player.UserId)

    	if not success then
    		return false, tostring(result)
    	end

    	Invites[inviteId] = nil

    	return true
    end

    createRoomFunction.OnServerInvoke = function(player, roomData)
        local success, roomOrError, createError = pcall(function()
            return self:CreateRoom(player, roomData)
        end)

        if not success then
            return nil, tostring(roomOrError)
        end

        if not roomOrError then
            return nil, tostring(createError)
        end

        return roomOrError
    end

    listRoomsFunction.OnServerInvoke = function(_, includePrivateRooms)
        return self:ListRooms(includePrivateRooms == true)
    end

    getPlayersBusyFunction.OnServerInvoke = function(_, playerUserIds)
        local busyStatuses = {}

        local players = Players:GetPlayers()

        for _, player in ipairs(players) do
            local userId = player.UserId
            busyStatuses[userId] = false

            for _, room in pairs(self.roomsById) do
                if table.find(room.playerUserIds, userId) then
                    busyStatuses[userId] = true
                    break
                end
            end
        end

        return busyStatuses
    end

    getRoomFunction.OnServerInvoke = function(_, roomId)
        return self:GetRoom(roomId)
    end

    joinRoomFunction.OnServerInvoke = function(player, roomId, invite)
        print("Player", player.Name, "is attempting to join room", roomId) -- debug

        local room = self.roomsById[roomId]

        if not room then
            return false, string.format("Room %s was not found", tostring(roomId))
        end

        if room.isPrivate and not invite then
            return false, "This room is private."
        end

        if invite then
            local inviteData = Invites[invite.id]

            if not inviteData then
                return false, "Invite not found or expired"
            end

            if inviteData.inviteeUserId ~= player.UserId then
                return false, "This invite is not for the invoking player"
            end

            if inviteData.roomId ~= roomId then
                return false, "This invite is not for the specified room"
            end

            Invites[invite.id] = nil
        end

        local success, roomOrError = self:AddPlayerToRoom(roomId, player.UserId)

        if not success then
            return false, tostring(roomOrError)
        end

        return roomOrError
    end

    leaveRoomFunction.OnServerInvoke = function(player, data)

        local roomId = data.roomId
        local userId = data.userId

        local room = self.roomsById[roomId]

        if roomId == nil or userId == nil then
            return false, "roomId and userId are required"
        end

        if userId ~= player.UserId then
            if data.isKick then
                if room.ownerUserId ~= player.UserId then
                    return false, "Only the room owner can kick players"
                end
                self:BroadcastKickPlayer(userId)
            else
                return false, "userId must match the invoking player's UserId"
            end
        end

        if userId == room.ownerUserId then
            return self:DeleteRoom(roomId)
        end

        return true, self:RemovePlayerFromRoom(roomId, userId)
    end

    self.roomUpdatesEvent = roomUpdatesEvent
    self.playerStatusChangedEvent = playerStatusChangedEvent
    self.joinedRoomEvent = joinedRoomEvent
    self.leftRoomEvent = leftRoomEvent
    self.startGameEvent = startGameEvent
    self.invitePlayerFunction = invitePlayerFunction
    self.playerInvitedEvent = playerInvitedEvent
end

function LobbyService:BroadcastPlayerInvited(targetPlayerUserId, invite)
    if not self.playerInvitedEvent then
        return
    end

    local targetPlayer = Players:GetPlayerByUserId(targetPlayerUserId)

    if targetPlayer then
        self.playerInvitedEvent:FireClient(targetPlayer, invite)
    end
end

function LobbyService:BroadcastStartGame(roomId)
    if not self.startGameEvent then
        return
    end

    local room = self.roomsById[roomId]

    if not room then
        return
    end

    for _, roomPlayer in ipairs(getPlayersInRoom(room)) do
        self.startGameEvent:FireClient(roomPlayer, roomId)
    end
end

function LobbyService:BroadcastRoomUpdate(action, room)
    if not self.roomUpdatesEvent then
        return
    end
    self.roomUpdatesEvent:FireAllClients(action, buildRoomSnapshot(room))
end

function LobbyService:BroadcastJoinedRoom(playerUserId, room)
    if not self.joinedRoomEvent then
        return
    end

    local roomSnapshot = buildRoomSnapshot(room)

    for _, roomPlayer in ipairs(getPlayersInRoom(room)) do
        self.joinedRoomEvent:FireClient(roomPlayer, playerUserId, roomSnapshot)
    end
end

function LobbyService:BroadcastKickPlayer(playerUserId)
    if not self.leftRoomEvent then
        return
    end
    local targetPlayer = Players:GetPlayerByUserId(playerUserId)
    self.leftRoomEvent:FireClient(targetPlayer, playerUserId, {
        isKick = true,
    })
end

function LobbyService:BroadcastLeftRoom(playerUserId, room)
    if not self.leftRoomEvent then
        return
    end

    local roomSnapshot = buildRoomSnapshot(room)

    for _, roomPlayer in ipairs(getPlayersInRoom(room)) do
        self.leftRoomEvent:FireClient(roomPlayer, playerUserId, roomSnapshot)
    end
end

function LobbyService:BroadcastPlayerStatusChange(roomId, playerUserId, newStatus)
    if not self.playerStatusChangedEvent then
        return
    end

    local receivers = {}
    local room = self.roomsById[roomId]
    local playersIds = room and room.playerUserIds or {}

    for i,v in pairs(playersIds) do
        local player = Players:GetPlayerByUserId(v)
        if player then
            table.insert(receivers, player)
        end
    end
    
    for i,v in pairs(receivers) do
        if v and v:IsA("Player") then
            self.playerStatusChangedEvent:FireClient(v, roomId, playerUserId, newStatus)
        end
    end
end

function LobbyService:GetPlayerRoomId(playerUserId)
    for roomId, room in pairs(self.roomsById) do
        if table.find(room.playerUserIds, playerUserId) then
            return roomId
        end
    end

    return nil
end

function LobbyService:GenerateRoomId()
    return HttpService:GenerateGUID(false)
end

function LobbyService:GenerateInvite(playerInviter, playerInvitee)
	local inviteId = self:GenerateInviteId()

	local invite = {
		id = inviteId,
		inviterUserId = playerInviter.UserId,
		inviteeUserId = playerInvitee.UserId,
		expiresAt = os.time() + 12,
	}

	Invites[inviteId] = invite

	task.delay(12, function()
		if Invites[inviteId] == invite then
			Invites[inviteId] = nil
		end
	end)

	return invite
end

function LobbyService:GenerateInviteId()
    local Id

	repeat
		Id = HttpService:GenerateGUID(false)
	until not Invites[Id]

	return Id
end

function LobbyService:GenerateAccessCode()
    return string.upper(string.sub(HttpService:GenerateGUID(false), 1, 6))
end

function LobbyService:ValidateCreateRoomPayload(owner, roomData)
    assert(typeof(owner) == "Instance" and owner:IsA("Player"), "CreateRoom expects a valid Player owner")

    roomData = roomData or {}

    local roomName = roomData.name or string.format("%s's Room", owner.Name)
    local maxPlayers = roomData.maxPlayers or DEFAULT_MAX_PLAYERS
    local roomType = roomData.roomType

    if roomType ~= nil then
        assert(type(roomType) == "string", "roomType must be a string")

        local normalizedRoomType = string.lower(trimString(roomType))
        assert(normalizedRoomType == "public" or normalizedRoomType == "private", "roomType must be Public or Private")

        roomType = normalizedRoomType == "private" and "Private" or "Public"
    else
        roomType = roomData.isPrivate == true and "Private" or "Public"
    end

    local isPrivate = roomType == "Private"
    local accessCode = nil

    assert(type(roomName) == "string", "Room name must be a string")
    roomName = trimString(roomName)
    assert(roomName ~= "", "Room name cannot be empty")

    assert(type(maxPlayers) == "number", "maxPlayers must be a number")
    maxPlayers = math.floor(maxPlayers)
    assert(maxPlayers >= MIN_MAX_PLAYERS and maxPlayers <= MAX_MAX_PLAYERS, string.format("maxPlayers must be between %d and %d", MIN_MAX_PLAYERS, MAX_MAX_PLAYERS))

    if isPrivate then
        local providedAccessCode = roomData.accessCode

        if providedAccessCode ~= nil then
            assert(type(providedAccessCode) == "string", "accessCode must be a string")

            providedAccessCode = string.upper(trimString(providedAccessCode))

            if providedAccessCode ~= "" then
                accessCode = providedAccessCode
            end
        end

        if not accessCode then
            accessCode = self:GenerateAccessCode()
        end
    end

    return {
        name = roomName,
        maxPlayers = maxPlayers,
        roomType = roomType,
        isPrivate = isPrivate,
        accessCode = accessCode,
    }
end

function LobbyService:GetRoom(roomId)
    ensureServiceState(self)

    local room = self.roomsById[roomId]

    if not room then
        return nil, string.format("Room %s was not found", tostring(roomId))
    end

    return buildRoomSnapshot(room)
end

function LobbyService:GetRoomByOwner(ownerUserId)
    ensureServiceState(self)

    local roomId = self.roomIdsByOwner[ownerUserId]

    if not roomId then
        return nil, string.format("Owner %s does not have a room", tostring(ownerUserId))
    end

    return self:GetRoom(roomId)
end

function LobbyService:RemovePlayerFromRoom(roomId, playerUserId)
    ensureServiceState(self)

    local room = self.roomsById[roomId]
    if not room then
        return false
    end

    for index, userId in ipairs(room.playerUserIds) do
        if userId == playerUserId then
            table.remove(room.playerUserIds, index)
            room.playerStatuses[playerUserId] = nil
            room.updatedAt = os.time()
            self:BroadcastLeftRoom(playerUserId, room)
            self:BroadcastRoomUpdate("updated", room)
            return true
        end
    end

    return false
end

function LobbyService:AddPlayerToRoom(roomId, playerUserId)
    ensureServiceState(self)

    local room = self.roomsById[roomId]

    if not room then
        return false, string.format("Room %s was not found", tostring(roomId))
    end

    if table.find(room.playerUserIds, playerUserId) then
        return true, buildRoomSnapshot(room)
    end

    if #room.playerUserIds >= room.maxPlayers then
        return false, "Room is full"
    end

    table.insert(room.playerUserIds, playerUserId)
    room.playerStatuses[playerUserId] = room.playerStatuses[playerUserId] or "NotReady"
    room.updatedAt = os.time()
    self:BroadcastJoinedRoom(playerUserId, room)
    self:BroadcastRoomUpdate("updated", room)
    return true, buildRoomSnapshot(room)
end

function LobbyService:CreateRoom(owner, roomData)
    ensureServiceState(self)

    local validatedRoomData = self:ValidateCreateRoomPayload(owner, roomData)
    local existingRoomId = self.roomIdsByOwner[owner.UserId]

    if existingRoomId then
        return nil, string.format("Player %s already owns room %s", owner.Name, existingRoomId)
    end

    local now = os.time()
    local room = {
        id = self:GenerateRoomId(),
        ownerUserId = owner.UserId,
        ownerName = owner.Name,
        name = validatedRoomData.name,
        maxPlayers = validatedRoomData.maxPlayers,
        roomType = validatedRoomData.roomType,
        isPrivate = validatedRoomData.isPrivate,
        accessCode = validatedRoomData.accessCode,
        playerUserIds = { owner.UserId },
        playerStatuses = { [owner.UserId] = "NotReady" },
        createdAt = now,
        updatedAt = now,
    }

    self.roomsById[room.id] = room
    self.roomIdsByOwner[owner.UserId] = room.id

    self:BroadcastRoomUpdate("created", room)

    return buildRoomSnapshot(room)
end

function LobbyService:GetRoom(roomId)
    ensureServiceState(self)

    local room = self.roomsById[roomId]

    if not room then
        return nil, string.format("Room %s was not found", tostring(roomId))
    end

    return buildRoomSnapshot(room)
end

function LobbyService:GetRoomByOwner(ownerUserId)
    ensureServiceState(self)

    local roomId = self.roomIdsByOwner[ownerUserId]

    if not roomId then
        return nil, string.format("Owner %s does not have a room", tostring(ownerUserId))
    end

    return self:GetRoom(roomId)
end

function LobbyService:ListRooms(includePrivateRooms)
    ensureServiceState(self)

    local rooms = {}

    for _, room in pairs(self.roomsById) do
        if includePrivateRooms or not room.isPrivate then
            table.insert(rooms, buildRoomSnapshot(room))
        end
    end

    table.sort(rooms, function(leftRoom, rightRoom)
        return leftRoom.createdAt < rightRoom.createdAt
    end)

    return rooms
end

function LobbyService:UpdateRoom(roomId, updates)
    ensureServiceState(self)

    local room = self.roomsById[roomId]

    if not room then
        return nil, string.format("Room %s was not found", tostring(roomId))
    end

    updates = updates or {}

    if updates.name ~= nil then
        assert(type(updates.name) == "string", "Room name must be a string")

        local trimmedName = string.gsub(updates.name, "^%s*(.-)%s*$", "%1")
        assert(trimmedName ~= "", "Room name cannot be empty")

        room.name = trimmedName
    end

    if updates.maxPlayers ~= nil then
        assert(type(updates.maxPlayers) == "number", "maxPlayers must be a number")

        local maxPlayers = math.floor(updates.maxPlayers)
        assert(maxPlayers >= MIN_MAX_PLAYERS and maxPlayers <= MAX_MAX_PLAYERS, string.format("maxPlayers must be between %d and %d", MIN_MAX_PLAYERS, MAX_MAX_PLAYERS))
        assert(maxPlayers >= #room.playerUserIds, "maxPlayers cannot be lower than current room occupancy")

        room.maxPlayers = maxPlayers
    end

    if updates.isPrivate ~= nil then
        assert(type(updates.isPrivate) == "boolean", "isPrivate must be a boolean")

        room.isPrivate = updates.isPrivate
        room.roomType = room.isPrivate and "Private" or "Public"

        if room.isPrivate and not room.accessCode then
            room.accessCode = self:GenerateAccessCode()
        elseif not room.isPrivate then
            room.accessCode = nil
        end
    end

    if updates.accessCode ~= nil then
        assert(type(updates.accessCode) == "string", "accessCode must be a string")
        room.accessCode = string.upper(updates.accessCode)
    end

    room.updatedAt = os.time()

    self:BroadcastRoomUpdate("updated", room)

    return buildRoomSnapshot(room)
end

function LobbyService:DeleteRoom(roomId)
    local room = self.roomsById[roomId]
    room["isDisband"] = true

    if not room then
        return nil, string.format("Room %s was not found", tostring(roomId))
    end

    for _, playerUserId in ipairs(room.playerUserIds) do
        self:BroadcastLeftRoom(playerUserId, room)
    end

    self.roomsById[roomId] = nil
    self.roomIdsByOwner[room.ownerUserId] = nil

    self:BroadcastRoomUpdate("deleted", room)

    return buildRoomSnapshot(room)
end

function LobbyService:HandlePlayerRemoving(player)
    local ownedRoomId = self.roomIdsByOwner[player.UserId]

    if ownedRoomId then
        self:DeleteRoom(ownedRoomId)
        return
    end

    for _, room in pairs(self.roomsById) do
        if table.find(room.playerUserIds, player.UserId) then
            self:RemovePlayerFromRoom(room.id, player.UserId)
            return
        end
    end
end

return LobbyService