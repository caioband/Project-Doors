local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local PlayerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
local SharedModules = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SharedModules")

local GuiObjectsUtils = require(SharedModules.GuiObjectsUtils)

local TextBoxConnections = {}

local CREATE_ROOM_FUNCTION_NAME = "CreateRoom" --- remote function 
local ROOM_TYPES = {
    {
        label = "Public",
        isPrivate = false,
    },
    {
        label = "Private",
        isPrivate = true,
    },
}

local MAX_PLAYERS_OPTIONS = {
    {
        label = "1 player",
        value = 1,
    },
    {
        label = "2 players",
        value = 2,
    },
    {
        label = "3 players",
        value = 3,
    },
    {
        label = "4 players",
        value = 4,
    },
}

local CreateRoomController = {}

local LobbyController
local RoomOptionsController

local function trimString(value)
    return string.gsub(value, "^%s*(.-)%s*$", "%1")
end

local function findFirstDescendant(instance, predicate)
    for _, descendant in ipairs(instance:GetDescendants()) do
        if predicate(descendant) then
            return descendant
        end
    end

    return nil
end

local function getButtonDisplayText(button)
    if button:IsA("TextButton") then
        return button.Text
    end

    local textLabel = findFirstDescendant(button, function(descendant)
        return descendant:IsA("TextLabel")
    end)

    return textLabel and textLabel.Text or nil
end

local function notify(title, text)
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = title,
            Text = text,
            Duration = 4,
        })
    end)
end

function CreateRoomController:GetCreateRoomFrame()
    local hud = PlayerGui:WaitForChild("Hud")
    return hud:WaitForChild("CreateRoom")
end

function CreateRoomController:GetFormFrame()
    return self:GetCreateRoomFrame():WaitForChild("Frame")
end

function CreateRoomController:GetSectionTextBox(sectionName)
    local section = self:GetFormFrame():WaitForChild(sectionName)
    local template = section:WaitForChild("SectionSlotTemplate")

    return template:WaitForChild("TextBox")
end

function CreateRoomController:GetRoomTypeWidgets()
    local roomTypeSection = self:GetFormFrame():WaitForChild("RoomType")
    local template = roomTypeSection:WaitForChild("SectionSlotTemplate")

    return template:WaitForChild("RoomTypeLabel"), template:WaitForChild("ArrowPrevious"), template:WaitForChild("ArrowNext")
end

function CreateRoomController:GetMaxPlayersWidgets()
    local maxPlayersSection = self:GetFormFrame():WaitForChild("MaxPlayers")
    local template = maxPlayersSection:WaitForChild("SectionSlotTemplate")

    return template:WaitForChild("MaxPlayersLabel"), template:WaitForChild("ArrowPrevious"), template:WaitForChild("ArrowNext")
end

function CreateRoomController:GetCreateButton()
    if self.createButton and self.createButton.Parent then
        return self.createButton
    end

    local createRoomFrame = self:GetCreateRoomFrame()
    local fallbackButton = nil

    for _, descendant in ipairs(createRoomFrame:GetChildren()) do
        if descendant:IsA("GuiButton") then
            local buttonText = getButtonDisplayText(descendant)

            if buttonText == "Create Room" or buttonText == "Create" then
                self.createButton = descendant
                return self.createButton
            end

            if buttonText ~= "Back" then
                fallbackButton = fallbackButton or descendant
            end
        end
    end

    self.createButton = fallbackButton

    return self.createButton
end

function CreateRoomController:GetBackButton()
    if self.backButton and self.backButton.Parent then
        return self.backButton
    end

    local createRoomFrame = self:GetCreateRoomFrame()

    for _, child in ipairs(createRoomFrame:GetChildren()) do
        if child:IsA("GuiButton") and getButtonDisplayText(child) == "Back" then
            self.backButton = child
            return self.backButton
        end
    end

    self.backButton = createRoomFrame:FindFirstChild("Back")

    return self.backButton
end

function CreateRoomController:SetupRoomRemotes()
    if self.createRoomFunction then
        return
    end

    local commsFolder = ReplicatedStorage:WaitForChild("Comms")
    local lobbyFolder = commsFolder:WaitForChild("Lobby")

    self.createRoomFunction = lobbyFolder:WaitForChild(CREATE_ROOM_FUNCTION_NAME)
end

function CreateRoomController:GetSelectedRoomType()
    return ROOM_TYPES[self.selectedRoomTypeIndex or 1]
end

function CreateRoomController:GetSelectedMaxPlayers()
    return MAX_PLAYERS_OPTIONS[self.selectedMaxPlayersIndex or 1]
end

function CreateRoomController:ApplySelectedRoomType()
    local roomTypeLabel = self:GetRoomTypeWidgets()
    local roomType = self:GetSelectedRoomType()
    local passwordBox = self:GetSectionTextBox("RoomPass")

    roomTypeLabel.Text = roomType.label
    passwordBox.TextEditable = roomType.isPrivate

    if roomType.isPrivate then
        passwordBox.PlaceholderText = "Enter a password..."
        passwordBox.Parent.Parent.Visible = true
        return
    end

    passwordBox.Text = ""
    passwordBox.PlaceholderText = "No password for public rooms"
    passwordBox.Parent.Parent.Visible = false
end

function CreateRoomController:ApplySelectedMaxPlayers()
    local maxPlayersLabel = self:GetMaxPlayersWidgets()
    local maxPlayersOption = MAX_PLAYERS_OPTIONS[self.selectedMaxPlayersIndex or 1]

    maxPlayersLabel.Text = maxPlayersOption.label
end

function CreateRoomController:RotateRoomType(step)
    local roomTypeCount = #ROOM_TYPES
    local currentIndex = self.selectedRoomTypeIndex or 1

    self.selectedRoomTypeIndex = ((currentIndex - 1 + step) % roomTypeCount) + 1
    self:ApplySelectedRoomType()
end

function CreateRoomController:RotateMaxPlayers(step)
    local maxPlayersCount = #MAX_PLAYERS_OPTIONS
    local currentIndex = self.selectedMaxPlayersIndex or 1

    self.selectedMaxPlayersIndex = ((currentIndex - 1 + step) % maxPlayersCount) + 1
    local maxPlayersOption = MAX_PLAYERS_OPTIONS[self.selectedMaxPlayersIndex]
    local maxPlayersLabel, _, _ = self:GetMaxPlayersWidgets()

    maxPlayersLabel.Text = maxPlayersOption.label
end

function CreateRoomController:BindRoomTypeCarousel()
    if self.roomTypeCarouselBound then
        return
    end

    local _, previousButton, nextButton = self:GetRoomTypeWidgets()

    previousButton.Activated:Connect(function()
        print("Previous room type")
        self:RotateRoomType(-1)
    end)

    nextButton.Activated:Connect(function()
        print("Next room type")
        self:RotateRoomType(1)
    end)

    self.roomTypeCarouselBound = true
end

function CreateRoomController:BindMaxPlayersCarousel()
    if self.maxPlayersCarouselBound then
        return
    end

    local _, previousButton, nextButton = self:GetMaxPlayersWidgets()

    previousButton.Activated:Connect(function()
        print("Previous max players")
        self:RotateMaxPlayers(-1)
    end)

    nextButton.Activated:Connect(function()
        print("Next max players")
        self:RotateMaxPlayers(1)
    end)

    self.maxPlayersCarouselBound = true
end

function CreateRoomController:ResetForm()
    local roomNameBox = self:GetSectionTextBox("RoomName")
    local passwordBox = self:GetSectionTextBox("RoomPass")

    roomNameBox.Text = ""
    passwordBox.Text = ""
    self.selectedRoomTypeIndex = 1
    self.selectedMaxPlayersIndex = 1

    self:ApplySelectedRoomType()
    self:ApplySelectedMaxPlayers()
end

function CreateRoomController:BuildCreateRoomPayload()
    local roomName = trimString(self:GetSectionTextBox("RoomName").Text)
    local maxPlayersValue = trimString(self:GetSelectedMaxPlayers().value)
    local accessCode = trimString(self:GetSectionTextBox("RoomPass").Text)
    local roomType = self:GetSelectedRoomType()
    local payload = {
        roomType = roomType.label,
    }

    if roomName ~= "" then
        payload.name = roomName
    end

    if maxPlayersValue then
        local maxPlayers = tonumber(maxPlayersValue)

        if not maxPlayers then
            return nil, "Max players must be a number."
        end

        payload.maxPlayers = maxPlayers
    end

    if roomType.isPrivate and accessCode ~= "" then
        payload.accessCode = accessCode
    end

    return payload
end

function CreateRoomController:ReturnToRoomOptions()
    local hud = PlayerGui:WaitForChild("Hud")
    local createRoom = hud:WaitForChild("CreateRoom")
    local roomOptions = hud:WaitForChild("RoomOptions")

    createRoom.Visible = false
    roomOptions.Visible = true
    RoomOptionsController:BindOptionsButtons()
end

function CreateRoomController:SubmitCreateRoom()
    if self.isSubmitting then
        return
    end

    local payload, payloadError = self:BuildCreateRoomPayload()

    if not payload then
        notify("Create Room", payloadError)
        return
    end

    self.isSubmitting = true

    local success, roomOrError, createError = pcall(function()
        return self.createRoomFunction:InvokeServer(payload)
    end)

    self.isSubmitting = false

    if not success then
        notify("Create Room", tostring(roomOrError))
        return
    end

    if not roomOrError then
        notify("Create Room", tostring(createError or "Could not create room."))
        return
    end

    local notificationText = string.format("Room '%s' created.", roomOrError.name)

    if roomOrError.isPrivate and roomOrError.accessCode then
        notificationText = string.format("Room '%s' created. Code: %s", roomOrError.name, roomOrError.accessCode)
    end

    notify("Create Room", notificationText)
    self:ResetForm()
    self:ClearTextBoxConnections()
    self:ReturnToRoomOptions()

    if LobbyController and LobbyController.roomUpdatesEvent and LobbyController:GetJoinRoomFrame().Visible then
        LobbyController:FetchAndRenderRooms()
    end
end

function CreateRoomController:BindActionButtons()
    if self.actionButtonsBound then
        return
    end

    local backButton = self:GetBackButton()
    local createButton = self:GetCreateButton()

    if backButton then
        backButton.Activated:Connect(function()
            print("Back to room options")
            self:ResetForm()
            self:ReturnToRoomOptions()
        end)
    end

    if createButton then
        createButton.Activated:Connect(function()
            print("Submit create room form")
            self:SubmitCreateRoom()
        end)
    end

    self.actionButtonsBound = true
end

function CreateRoomController:Open()
    self:SetupRoomRemotes()
    self:BindRoomTypeCarousel()
    self:BindMaxPlayersCarousel()
    self:BindActionButtons()
    self:AttachLimiterToTextBoxes()
    self:ResetForm()
end

function CreateRoomController:ClearTextBoxConnections()
    for _, connection in pairs(TextBoxConnections) do
        connection:Disconnect()
    end

    TextBoxConnections = {}
end

function CreateRoomController:AttachLimiterToTextBoxes()
    local createRoomFrame = self:GetCreateRoomFrame()
    self:ClearTextBoxConnections()
    for i,v in pairs(createRoomFrame:GetDescendants()) do
        
        local textBox = v:IsA("TextBox")

        if textBox then
            table.insert(TextBoxConnections, GuiObjectsUtils:AttachLimitToTextBox(v, v:GetAttribute("CharacterLimit") or 20))
        end
    end
end

function CreateRoomController:Start()
    LobbyController = self.GetController("LobbyController")
    RoomOptionsController = self.GetController("RoomOptionsController")
    self.selectedRoomTypeIndex = 1
    self.selectedMaxPlayersIndex = 1
end

return CreateRoomController