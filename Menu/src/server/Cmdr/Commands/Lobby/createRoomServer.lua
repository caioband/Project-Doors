local ServerScriptService = game:GetService("ServerScriptService")

local LobbyService = require(ServerScriptService.Server.Services.LobbyService)

return function(context, name, maxPlayers, isPrivate, accessCode)
    local roomData = {}

    if name and name ~= "" then
        roomData.name = name
    end

    if maxPlayers ~= nil then
        roomData.maxPlayers = maxPlayers
    end

    if isPrivate ~= nil then
        roomData.isPrivate = isPrivate
    end

    if accessCode and accessCode ~= "" then
        roomData.accessCode = accessCode
    end

    local success, roomOrError, createError = pcall(function()
        return LobbyService:CreateRoom(context.Executor, roomData)
    end)

    if not success then
        return string.format("Failed to create room: %s", tostring(roomOrError))
    end

    if not roomOrError then
        return string.format("Failed to create room: %s", tostring(createError))
    end

    return string.format(
        "Room '%s' created with id %s (%d/%d).",
        roomOrError.name,
        roomOrError.id,
        #(roomOrError.playerUserIds or {}),
        roomOrError.maxPlayers
    )
end