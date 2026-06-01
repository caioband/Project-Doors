local PlayerGui = game.Players.LocalPlayer:WaitForChild("PlayerGui")
local MenuController = require(script.Parent:WaitForChild("MenuController"))

local LobbyController
local CreateRoomController

local RoomOptionsController = {}

local function bindButton(button, attributeName, callback)
    if not button or button:GetAttribute(attributeName) then
        return
    end

    button:SetAttribute(attributeName, true)
    button.Activated:Connect(callback)
end

function RoomOptionsController:BindOptionsButtons()
    local Hud = PlayerGui:WaitForChild("Hud")
    local RoomOptions = Hud:WaitForChild("RoomOptions")
    local JoinRoom = Hud:WaitForChild("JoinRoom")
    local CreateRoom = Hud:WaitForChild("CreateRoom")

    local JoinRoomButton = RoomOptions:WaitForChild("JoinRoom")
    local CreateRoomButton = RoomOptions:WaitForChild("CreateRoom")
    local BackButton = RoomOptions:WaitForChild("Back")

    bindButton(BackButton, "RoomOptionsBound", function()
            RoomOptions.Visible = false
            MenuController:BindMenuButtons()
        end)

    bindButton(JoinRoomButton, "RoomOptionsBound", function()
            RoomOptions.Visible = false
            JoinRoom.Visible = true
            LobbyController:BindLobbyButtons()
        end)

    bindButton(CreateRoomButton, "RoomOptionsBound", function()
            RoomOptions.Visible = false
            CreateRoom.Visible = true
            CreateRoomController:Open()
        end)

end

function RoomOptionsController:Start()

    LobbyController = self.GetController("LobbyController")
    CreateRoomController = self.GetController("CreateRoomController")

end

return RoomOptionsController