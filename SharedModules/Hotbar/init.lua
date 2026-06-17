local Hotbar = {}

local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")

local UI = require(script.UI)
local DeviceController = require(script.Parent.DeviceController)

-- Callbacks de equipar/desequipar por item (chave = nome do item).
-- Vazio por padrao; preenchido externamente via Hotbar:SetItemCallbacks.
type ItemCallbacks = {
    OnEquip: ((item: any, slotNumber: number) -> ())?,
    OnUnequip: ((item: any, slotNumber: number) -> ())?,
}

Hotbar.Callbacks = {} :: { [string]: ItemCallbacks }

-- Registra (ou substitui) os callbacks de um item pelo nome.
function Hotbar:SetItemCallbacks(itemName: string, callbacks: ItemCallbacks)
    self.Callbacks[itemName] = callbacks
end

Hotbar.Slots = {
    [1] = {
       Current = nil,
       Equipped = false,
       Binds = {
           ["Console"] = Enum.KeyCode.DPadUp,
           ["PC"] = Enum.KeyCode.One,
       }
    },
    [2] = {
       Current = nil,
       Equipped = false,
       Binds = {
           ["Console"] = Enum.KeyCode.DPadRight,
           ["PC"] = Enum.KeyCode.Two,
       }
    },
    [3] = {
        Current = nil,
        Equipped = false,
        Binds = {
            ["Console"] = Enum.KeyCode.DPadDown,
            ["PC"] = Enum.KeyCode.Three,
        }
    },
    [4] = {
        Current = nil,
        Equipped = false,
        Binds = {
            ["Console"] = Enum.KeyCode.DPadLeft,
            ["PC"] = Enum.KeyCode.Four,
        }
    },
}

-- Fallbacks usados quando UserInputService:GetImageForKeyCode retorna "".
-- Cada entrada suporta uma imagem ({ Image = "rbxassetid://..." })
-- ou um texto instanciado em runtime ({ Text = "1" }).
local BindFallbacks = {
    [Enum.KeyCode.One] = { Text = "1" },
    [Enum.KeyCode.Two] = { Text = "2" },
    [Enum.KeyCode.Three] = { Text = "3" },
    [Enum.KeyCode.Four] = { Text = "4" },

    [Enum.KeyCode.DPadUp] = { Image = "rbxassetid://0" },
    [Enum.KeyCode.DPadRight] = { Image = "rbxassetid://0" },
    [Enum.KeyCode.DPadDown] = { Image = "rbxassetid://0" },
    [Enum.KeyCode.DPadLeft] = { Image = "rbxassetid://0" },
}

-- Descritor do bind para o dispositivo atual: { Image = ... } ou { Text = ... } (ou nil).
local function getBindIcon(slotInfo)
    local device = DeviceController:GetDevice()
    local keyCode = slotInfo.Binds[device]
    if not keyCode then
        return nil
    end

    local image = UserInputService:GetImageForKeyCode(keyCode)
    if image ~= "" then
        return { Image = image }
    end

    -- Sem glifo nativo para essa tecla: usa o fallback (imagem ou texto).
    return BindFallbacks[keyCode]
end

local function bindSlots(hotbar)
    for slotNumber in pairs(hotbar.Slots) do
        ContextActionService:UnbindAction("HotbarSlot" .. slotNumber)
    end

    local device = DeviceController:GetDevice()

    for slotNumber, slotInfo in pairs(hotbar.Slots) do
        local keyCode = slotInfo.Binds[device]
        if not keyCode then continue end

        -- Mantem o icone do bind atualizado para slots ocupados (ex: ao trocar de dispositivo).
        if slotInfo.Current then
            UI:SetBindIcon(slotNumber, getBindIcon(slotInfo))
        end

        ContextActionService:BindAction(
            "HotbarSlot" .. slotNumber,
            function(_, inputState)
                if inputState == Enum.UserInputState.Begin then
                    local slot = hotbar.Slots[slotNumber]
                    if slot and slot.Equipped then
                        hotbar:Unequip(slotNumber)
                    else
                        hotbar:Equip(slotNumber)
                    end
                end
                return Enum.ContextActionResult.Pass
            end,
            false,
            keyCode
        )
    end
end

function Hotbar:Start()
    UI:Render()
    bindSlots(self)

    UserInputService.LastInputTypeChanged:Connect(function()
        bindSlots(self)
    end)
end

function Hotbar:Equip(slotNumber: number)
    local slot = self.Slots[slotNumber]
    if not slot then
        warn("Invalid hotbar slot: " .. tostring(slotNumber))
        return
    end

    for i, s in pairs(self.Slots) do
        if s.Equipped then
            self:Unequip(i)
        end
    end

    slot.Equipped = true
    UI:SetEquipped(slotNumber, true)

    local item = slot.Current
    local callbacks = item and self.Callbacks[item.Name]
    if callbacks and callbacks.OnEquip then
        callbacks.OnEquip(item, slotNumber)
    end

    print("Slot " .. slotNumber .. " equipped")
end

function Hotbar:Unequip(slotNumber: number)
    local slot = self.Slots[slotNumber]
    if not slot then
        warn("Invalid hotbar slot: " .. tostring(slotNumber))
        return
    end

    slot.Equipped = false
    UI:SetEquipped(slotNumber, false)

    local item = slot.Current
    local callbacks = item and self.Callbacks[item.Name]
    if callbacks and callbacks.OnUnequip then
        callbacks.OnUnequip(item, slotNumber)
    end

    print("Slot " .. slotNumber .. " unequipped")
end

function Hotbar:AddItem(slotNumber: number, item)
    local slot = self.Slots[slotNumber]
    if not slot then
        warn("Invalid hotbar slot: " .. tostring(slotNumber))
        return
    end

    slot.Current = item
    print("Added item to slot " .. slotNumber)
end

-- Adiciona um item no primeiro slot livre e atualiza a UI. Retorna o slot usado ou nil se cheio.
function Hotbar:AddToFirstFreeSlot(item): number?
    for slotNumber, slot in ipairs(self.Slots) do
        if slot.Current == nil then
            self:AddItem(slotNumber, item)
            UI:AddSlot(slotNumber, getBindIcon(slot), item.Name)
            return slotNumber
        end
    end

    warn("Hotbar is full; could not add item")
    return nil
end

function Hotbar:RemoveItem(slotNumber: number)
    local slot = self.Slots[slotNumber]
    if not slot then
        warn("Invalid hotbar slot: " .. tostring(slotNumber))
        return
    end

    if slot.Equipped then
        self:Unequip(slotNumber)
    end

    slot.Current = nil
    print("Removed item from slot " .. slotNumber)
end

return Hotbar
