local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DEFAULT_MAX_PLAYERS = 4
local MIN_MAX_PLAYERS = 1
local MAX_MAX_PLAYERS = 8
local COMMS_FOLDER_NAME = "Comms"
local LOBBY_COMMS_FOLDER_NAME = "Lobby"
local CREATE_ROOM_FUNCTION_NAME = "CreateRoom"
local LIST_ROOMS_FUNCTION_NAME = "ListRooms"
local ROOM_UPDATES_EVENT_NAME = "RoomUpdates"

local LobbyService = {}

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
    }
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

    local roomUpdatesEvent = lobbyFolder:FindFirstChild(ROOM_UPDATES_EVENT_NAME)

    if not roomUpdatesEvent then
        roomUpdatesEvent = Instance.new("RemoteEvent")
        roomUpdatesEvent.Name = ROOM_UPDATES_EVENT_NAME
        roomUpdatesEvent.Parent = lobbyFolder
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
    print(roomUpdatesEvent)
    self.roomUpdatesEvent = roomUpdatesEvent
end

function LobbyService:BroadcastRoomUpdate(action, room)
    if not self.roomUpdatesEvent then
        return
    end
    self.roomUpdatesEvent:FireAllClients(action, buildRoomSnapshot(room))
end

function LobbyService:GenerateRoomId()
    return HttpService:GenerateGUID(false)
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

    if not room then
        return nil, string.format("Room %s was not found", tostring(roomId))
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
        for index, userId in ipairs(room.playerUserIds) do
            if userId == player.UserId then
                table.remove(room.playerUserIds, index)
                room.updatedAt = os.time()
                self:BroadcastRoomUpdate("updated", room)
                return
            end
        end
    end
end

return LobbyService