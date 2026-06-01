local PlayerGui = game.Players.LocalPlayer:WaitForChild("PlayerGui")

local LobbyController = {}
local RoomOptionsController


function LobbyController:BindLobbyButtons()
    local Hud = PlayerGui:WaitForChild("Hud")
    local JoinRoom = Hud:WaitForChild("JoinRoom")

    local BackButton = JoinRoom:WaitForChild("Back")

    BackButton.MouseButton1Click:Once(function()
        JoinRoom.Visible = false
        local RoomOptions = Hud:WaitForChild("RoomOptions")
        RoomOptions.Visible = true
        RoomOptionsController:BindOptionsButtons()
    end)    
end

function LobbyController:Start()
    RoomOptionsController = self.GetController("RoomOptionsController")
end

return LobbyController