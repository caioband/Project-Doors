local UI = {}
local SlotsPositions = {
    [1] = {SlotPosition = UDim2.fromScale(0.502, 0.197), BindIconPosition = UDim2.fromScale(0.5, 0.5)},
    [2] = {SlotPosition = UDim2.fromScale(0.806, 0.5), BindIconPosition = UDim2.fromScale(0.6, 0.5)},
    [3] = {SlotPosition = UDim2.fromScale(0.502, 0.805), BindIconPosition = UDim2.fromScale(0.7, 0.5)},
    [4] = {SlotPosition = UDim2.fromScale(0.202, 0.5), BindIconPosition = UDim2.fromScale(0.8, 0.5)},    
}

local ItemIcons = {
    ["Flashlight"] = "rbxassetid://120633219632034", 
}


local PlayerGui = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
local HotbarUI = PlayerGui:WaitForChild("SharedGuis"):WaitForChild("Hotbar")
local HotbarImage = HotbarUI.Frame:WaitForChild("ImageLabel")

-- Cor original (ImageColor3) de cada slot, capturada antes de ser destacado ao equipar.
local OriginalColors = {}


function UI:Render()
    HotbarUI.Enabled = true
end

-- Destaca o slot equipado deixando a imagem totalmente branca; ao desequipar, restaura a cor original.
function UI:SetEquipped(slotNumber: number, equipped: boolean)
    local slot = HotbarImage:FindFirstChild("Slot" .. slotNumber)
    if not slot then
        warn("Hotbar slot UI element not found for slot number: " .. tostring(slotNumber))
        return
    end

    if equipped then
        if OriginalColors[slotNumber] == nil then
            OriginalColors[slotNumber] = slot.ImageColor3
        end
        slot.ImageColor3 = Color3.new(1, 1, 1)
    elseif OriginalColors[slotNumber] then
        slot.ImageColor3 = OriginalColors[slotNumber]
    end
end

type BindDisplay = { Image: string?, Text: string? }

-- Cria (uma unica vez) o TextLabel usado para o fallback textual do bind, herdando o layout do BindIcon.
local function getOrCreateBindText(slotNumber: number, slot)
    local existing = slot:FindFirstChild("BindText")
    if existing then
        return existing
    end

    local bindIcon = slot.BindIcon
    local label = Instance.new("TextLabel")
    label.Name = "BindText"
    label.BackgroundTransparency = 1
    label.AnchorPoint = bindIcon.AnchorPoint
    label.Position = bindIcon.Position
    label.Size = bindIcon.Size
    label.ZIndex = bindIcon.ZIndex
    label.FontFace = Font.fromEnum(
        Enum.Font.Merriweather,
        Enum.FontWeight.Bold,
        Enum.FontStyle.Normal
    )
    label.TextColor3 = Color3.new(1, 1, 1)
    label.TextScaled = true
    label.Visible = false
    label.Parent = slot
    local stroke = Instance.new("UIStroke")
    stroke.Name = "TextStroke"
    stroke.Color = Color3.new(0, 0, 0)
    stroke.Thickness = 2
    stroke.Parent = label

    return label
end

-- Renderiza o bind de um slot: imagem, texto (instanciado em runtime) ou escondido.
function UI:SetBindIcon(slotNumber: number, bind: BindDisplay?)
    local slotInfo = SlotsPositions[slotNumber]
    local slot = HotbarImage:FindFirstChild("Slot" .. slotNumber)
    if not slotInfo or not slot then
        warn("Hotbar slot UI element not found for slot number: " .. tostring(slotNumber))
        return
    end

    local bindText = slot:FindFirstChild("BindText")

    if bind and bind.Image and bind.Image ~= "" then
        if bindText then
            bindText.Visible = false
        end
        slot.BindIcon.Position = slotInfo.BindIconPosition
        slot.BindIcon.Image = bind.Image
        slot.BindIcon.Visible = true
    elseif bind and bind.Text and bind.Text ~= "" then
        slot.BindIcon.Visible = false
        bindText = getOrCreateBindText(slotNumber, slot)
        bindText.Text = bind.Text
        bindText.Visible = true
    else
        slot.BindIcon.Visible = false
        if bindText then
            bindText.Visible = false
        end
    end
end

function UI:AddSlot(slotNumber: number, BindIcon: BindDisplay?, itemIcon: string)
    local slotInfo = SlotsPositions[slotNumber]
    if not slotInfo then
        warn("Invalid hotbar slot number: " .. tostring(slotNumber))
        return
    end

    local slot = HotbarImage:FindFirstChild("Slot" .. slotNumber)
    if not slot then
        warn("Hotbar slot UI element not found for slot number: " .. tostring(slotNumber))
        return
    end

    slot.Position = slotInfo.SlotPosition

    if not itemIcon or not ItemIcons[itemIcon] then
        slot.ItemIcon.Visible = false
        warn("No item icon provided for slot " .. slotNumber, itemIcon)
    else
        slot.Visible = true
        slot.Image = ItemIcons[itemIcon]
    end

    self:SetBindIcon(slotNumber, BindIcon)
end

return UI 