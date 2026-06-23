local UI = {}

-- Posicoes absolutas dos slots no layout Desktop (o anel). O layout Mobile usa UIListLayout,
-- entao nao definimos posicao manualmente la.
local DesktopSlotPositions = {
    [1] = UDim2.fromScale(0.502, 0.197),
    [2] = UDim2.fromScale(0.806, 0.5),
    [3] = UDim2.fromScale(0.502, 0.805),
    [4] = UDim2.fromScale(0.202, 0.5),
}

local ItemIcons = {
    ["Flashlight"] = "rbxassetid://120633219632034",
}


local PlayerGui = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
local HotbarUI = PlayerGui:WaitForChild("SharedGuis"):WaitForChild("Hotbar")
local HotbarFrame = HotbarUI:WaitForChild("Frame")

-- Os dois layouts da hotbar:
-- - Desktop: a ImageLabel (anel) com slots posicionados manualmente (teclado/controle).
-- - Mobile: a Frame "Mobile" com slots arranjados por UIListLayout (toque).
local Containers = {
    Desktop = HotbarFrame:WaitForChild("ImageLabel"),
    Mobile = HotbarFrame:WaitForChild("Mobile"),
}

UI.ActiveLayout = "Desktop"

-- Cor original (ImageColor3) de cada slot, capturada antes do destaque de equipado.
-- Chave = Instance do slot (cada layout tem seus proprios slots).
local OriginalColors = {}

-- Estado/conexao do botao de cada slot. Chave = Instance do slot. A conexao do Activated e
-- criada uma unica vez por botao; depois so atualizamos o callback ativo, evitando
-- desconectar/reconectar no meio de um toque.
local SlotButtonState = {}

local function getContainer(layout: string?)
    return Containers[layout or UI.ActiveLayout]
end

local function getSlot(slotNumber: number, layout: string?)
    local container = getContainer(layout)
    return container and container:FindFirstChild("Slot" .. slotNumber)
end

-- Desativa os botoes de um container (usado no layout inativo apos uma troca).
local function disableContainerButtons(container)
    for i = 1, 4 do
        local slot = container:FindFirstChild("Slot" .. i)
        if slot and slot:IsA("GuiButton") then
            slot.Active = false
            slot.Interactable = false
            slot.AutoButtonColor = false
            local state = SlotButtonState[slot]
            if state then
                state.onActivate = nil
            end
        end
    end
end

function UI:Render()
    HotbarUI.Enabled = true
end

-- Alterna entre o layout padrao (Desktop) e o de toque (Mobile): mostra o container alvo,
-- esconde e desativa os botoes do outro. Retorna true se o layout mudou.
function UI:SetActiveLayout(isMobile: boolean): boolean
    local target = isMobile and "Mobile" or "Desktop"
    if self.ActiveLayout == target then
        return false
    end

    self.ActiveLayout = target
    for name, container in pairs(Containers) do
        local active = name == target
        container.Visible = active
        if not active then
            disableContainerButtons(container)
        end
    end
    return true
end

-- Habilita/desabilita o toque no ImageButton do slot (no container ativo).
-- Quando ativo, o toque (Activated) chama onActivate; quando inativo, o botao deixa de
-- capturar input (Active/Interactable = false) e o callback e ignorado.
function UI:SetSlotButtonActive(slotNumber: number, active: boolean, onActivate: (() -> ())?)
    local slot = getSlot(slotNumber)
    if not slot or not slot:IsA("GuiButton") then
        warn("Hotbar slot button not found for slot number: " .. tostring(slotNumber))
        return
    end

    slot.Active = active
    slot.Interactable = active
    slot.AutoButtonColor = active

    local state = SlotButtonState[slot]
    if not state then
        state = {}
        SlotButtonState[slot] = state
        -- Conexao unica: o handler le sempre o callback atual do estado.
        state.connection = slot.Activated:Connect(function()
            local current = SlotButtonState[slot]
            if current and current.onActivate then
                current.onActivate()
            end
        end)
    end

    state.onActivate = active and onActivate or nil
end

-- Destaca o slot equipado deixando a imagem totalmente branca; ao desequipar, restaura a cor original.
function UI:SetEquipped(slotNumber: number, equipped: boolean)
    local slot = getSlot(slotNumber)
    if not slot then
        warn("Hotbar slot UI element not found for slot number: " .. tostring(slotNumber))
        return
    end

    if equipped then
        if OriginalColors[slot] == nil then
            OriginalColors[slot] = slot.ImageColor3
        end
        slot.ImageColor3 = Color3.new(1, 1, 1)
    elseif OriginalColors[slot] then
        slot.ImageColor3 = OriginalColors[slot]
    end
end

type BindDisplay = { Image: string?, Text: string? }

-- Cria (uma unica vez) o TextLabel usado para o fallback textual do bind, herdando o layout do BindIcon.
local function getOrCreateBindText(slot)
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

-- Renderiza o bind de um slot (no container ativo): imagem, texto (instanciado em runtime) ou escondido.
function UI:SetBindIcon(slotNumber: number, bind: BindDisplay?)
    local slot = getSlot(slotNumber)
    local bindIcon = slot and slot:FindFirstChild("BindIcon")
    if not slot or not bindIcon then
        warn("Hotbar slot UI element not found for slot number: " .. tostring(slotNumber))
        return
    end

    local bindText = slot:FindFirstChild("BindText")

    if bind and bind.Image and bind.Image ~= "" then
        if bindText then
            bindText.Visible = false
        end
        -- A posicao do BindIcon e a definida na GUI; nao a sobrescrevemos aqui.
        bindIcon.Image = bind.Image
        bindIcon.Visible = true
    elseif bind and bind.Text and bind.Text ~= "" then
        bindIcon.Visible = false
        bindText = getOrCreateBindText(slot)
        bindText.Text = bind.Text
        bindText.Visible = true
    else
        bindIcon.Visible = false
        if bindText then
            bindText.Visible = false
        end
    end
end

-- Renderiza o estado completo de um slot no container ativo: imagem do item + visibilidade,
-- destaque de equipado, bind e ativacao do botao de toque. Usado ao trocar de layout,
-- ao trocar de dispositivo e ao adicionar/remover itens.
function UI:RenderSlot(
    slotNumber: number,
    itemName: string?,
    equipped: boolean,
    bind: BindDisplay?,
    touchActive: boolean,
    onActivate: (() -> ())?
)
    local slot = getSlot(slotNumber)
    if not slot then
        warn("Hotbar slot UI element not found for slot number: " .. tostring(slotNumber))
        return
    end

    if itemName and ItemIcons[itemName] then
        slot.Image = ItemIcons[itemName]
        slot.Visible = true
    else
        slot.Visible = false
    end

    -- Posicao manual apenas no Desktop; o Mobile e arranjado por UIListLayout.
    if self.ActiveLayout == "Desktop" then
        local slotPosition = DesktopSlotPositions[slotNumber]
        if slotPosition then
            slot.Position = slotPosition
        end
    end

    self:SetBindIcon(slotNumber, bind)
    self:SetEquipped(slotNumber, equipped)
    self:SetSlotButtonActive(slotNumber, touchActive, onActivate)
end

return UI
