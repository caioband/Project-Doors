local ToggleLoading = {}
local PlayerGui = game.Players.LocalPlayer:WaitForChild("PlayerGui")
local SharedGuis = PlayerGui:WaitForChild("SharedGuis")

local Looping = false

local function updateText()
    local LoadingTextLabel = SharedGuis:WaitForChild("ToggleLoading").Frame.TextLabel

    local dotsIndexes = string.find(LoadingTextLabel.Text, "%.+")

    if dotsIndexes then
        local dots = string.sub(LoadingTextLabel.Text, dotsIndexes)
        if #dots >= 3 then
            LoadingTextLabel.Text = "Loading"
        else
            LoadingTextLabel.Text = LoadingTextLabel.Text .. "."
        end
    else
        LoadingTextLabel.Text = LoadingTextLabel.Text .. "."
    end
end

function ToggleLoading:Toggle(isLoading)
    local ToggleLoadingGui = SharedGuis:WaitForChild("ToggleLoading")
    ToggleLoadingGui.Frame.Visible = isLoading

    if isLoading then
        self:BindLoop()
    else
        self:UnbindLoop()
    end
end

function ToggleLoading:BindLoop()
    local LoadingIcon = SharedGuis:WaitForChild("ToggleLoading").Frame.ImageLabel
    Looping = true
    task.spawn(function()
        while Looping do
            task.wait(0.1)
            updateText()
            LoadingIcon.Rotation += 30
        end
    end)
end

function ToggleLoading:UnbindLoop()
    Looping = false
end

return ToggleLoading