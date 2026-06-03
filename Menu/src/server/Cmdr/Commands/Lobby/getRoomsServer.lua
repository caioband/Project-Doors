local ServerScriptService = game:GetService("ServerScriptService")

local LobbyService = require(ServerScriptService.Server.Services.LobbyService)

return function(context)
    local success, roomsOrError = pcall(function()
        return LobbyService:ListRooms()
    end)

    if not success then
        return string.format("Failed to get rooms: %s", tostring(roomsOrError))
    end

    if type(roomsOrError) ~= "table" then
        return string.format("Failed to get rooms: %s", tostring(roomsOrError))
    end

    if #roomsOrError == 0 then
        return "No rooms available."
    end

    local responseLines = {"Available rooms:"}

    print("Retrieved rooms:", roomsOrError)

    for _, roomData in ipairs(roomsOrError) do
        table.insert(responseLines, string.format(
            "- %s (ID: %s, %d/%d players)",
            roomData.name or "Unnamed Room",
            roomData.id,
            #(roomData.playerUserIds or {}),
            roomData.maxPlayers
        ))
    end

    return table.concat(responseLines, "\n")
end