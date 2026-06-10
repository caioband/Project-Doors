local PlayerGui = game.Players.LocalPlayer:WaitForChild("PlayerGui")
local MenuController = require(script.Parent:WaitForChild("MenuController"))

local LobbyController
local CreateRoomController

local RoomOptionsController = {}

RoomOptionsController.Connections = {}

local function bindButton(controller, button, key, callback)
	if not button then
		return
	end

	controller:UnbindButton(key)

	controller.Connections[key] = button.Activated:Connect(callback)
end

function RoomOptionsController:UnbindButton(key)
	local connection = self.Connections[key]

	if connection then
		connection:Disconnect()
		self.Connections[key] = nil
	end
end

function RoomOptionsController:UnbindButtons()
	for key, connection in pairs(self.Connections) do
		connection:Disconnect()
		self.Connections[key] = nil
	end
end

function RoomOptionsController:BindOptionsButtons()
	local Hud = PlayerGui:WaitForChild("Hud")
	local RoomOptions = Hud:WaitForChild("RoomOptions")
	local JoinRoom = Hud:WaitForChild("JoinRoom")
	local CreateRoom = Hud:WaitForChild("CreateRoom")

	local JoinRoomButton = RoomOptions:WaitForChild("JoinRoom")
	local CreateRoomButton = RoomOptions:WaitForChild("CreateRoom")
	local BackButton = RoomOptions:WaitForChild("Back")

	bindButton(self, BackButton, "Back", function()
		RoomOptions.Visible = false

		self:UnbindButtons()
		MenuController:BindMenuButtons()
	end)

	bindButton(self, JoinRoomButton, "JoinRoom", function()
		RoomOptions.Visible = false
		JoinRoom.Visible = true

		self:UnbindButtons()
		LobbyController:BindLobbyButtons()
	end)

	bindButton(self, CreateRoomButton, "CreateRoom", function()
		RoomOptions.Visible = false
		CreateRoom.Visible = true

		self:UnbindButtons()
		CreateRoomController:Open()
	end)
end

function RoomOptionsController:Start()

    LobbyController = self.GetController("LobbyController")
    CreateRoomController = self.GetController("CreateRoomController")

end

return RoomOptionsController