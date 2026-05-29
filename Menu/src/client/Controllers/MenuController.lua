local MenuController = {}
local MenuUI3D = workspace:WaitForChild("MenuUI3D")


local function GetButtonPartFromMenuUI3D(buttonName) : Part
    return MenuUI3D:WaitForChild(buttonName)
end


function MenuController:SetupPlayOptions()
   
end

function MenuController:PlayButtonCallback()
    self:SetupPlayOptions()
end

function MenuController:BindMenuButtons()
    local PlayPart = MenuUI3D:WaitForChild("Play")
    local PlayButton = PlayPart:FindFirstChildWhichIsA("ImageButton", true)

    local CreditsPart = MenuUI3D:WaitForChild("Credits") 
    local CreditsButton = CreditsPart:FindFirstChildWhichIsA("ImageButton", true)

    if PlayButton then
        PlayButton.MouseButton1Up:Connect(function()
            self:PlayButtonCallback()
        end)
    end
    if CreditsButton then
        CreditsButton.MouseButton1Up:Connect(function()
            print("Credits button clicked")
        end)
    end
end

function MenuController:Start()
    self:BindMenuButtons()
end 

return MenuController