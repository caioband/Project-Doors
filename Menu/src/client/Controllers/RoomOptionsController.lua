local PlayerGui = game.Players.LocalPlayer:WaitForChild("PlayerGui")
local MenuController = require(script.Parent:WaitForChild("MenuController"))

local LobbyController

local RoomOptionsController = {}

function RoomOptionsController:BindOptionsButtons()
    local Hud = PlayerGui:WaitForChild("Hud")
    local RoomOptions = Hud:WaitForChild("RoomOptions")
    local JoinRoom = Hud:WaitForChild("JoinRoom")

    local JoinRoomButton = RoomOptions:WaitForChild("JoinRoom")
    local CreateRoomButton = RoomOptions:WaitForChild("CreateRoom")
    local BackButton = RoomOptions:WaitForChild("Back")

    if BackButton then
        BackButton.MouseButton1Click:Once(function()
            RoomOptions.Visible = false
            MenuController:BindMenuButtons()
        end)
    end

    if JoinRoomButton then
        JoinRoomButton.MouseButton1Click:Once(function()
            RoomOptions.Visible = false
            JoinRoom.Visible = true
            LobbyController:BindLobbyButtons()
        end)
    end

end

function RoomOptionsController:Start()

    LobbyController = self.GetController("LobbyController")

end

return RoomOptionsController