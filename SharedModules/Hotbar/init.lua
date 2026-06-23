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

-- Alterna o estado do slot (equipa se livre, desequipa se ja equipado).
local function toggleSlot(hotbar, slotNumber: number)
    local slot = hotbar.Slots[slotNumber]
    if slot and slot.Equipped then
        hotbar:Unequip(slotNumber)
    else
        hotbar:Equip(slotNumber)
    end
end

-- Reconfigura toda a hotbar para o dispositivo atual:
-- - alterna entre o layout padrao (Desktop/anel) e o de toque (Mobile);
-- - renderiza cada slot (item, destaque, bind) no layout ativo;
-- - em telas de toque ativa o ImageButton do slot; nos demais vincula a tecla/controle.
local function refreshSlots(hotbar)
    local device = DeviceController:GetDevice()
    -- Usamos TouchEnabled (e nao device == "Mobile") porque o emulador do Studio e aparelhos
    -- hibridos reportam KeyboardEnabled = true, o que faria o DeviceController classificar
    -- como "PC" e deixaria a hotbar de toque desativada mesmo com toque disponivel.
    local isTouch = UserInputService.TouchEnabled

    -- Mostra a hotbar de toque quando ha tela sensivel ao toque; senao, a padrao.
    UI:SetActiveLayout(isTouch)

    for slotNumber, slotInfo in pairs(hotbar.Slots) do
        ContextActionService:UnbindAction("HotbarSlot" .. slotNumber)

        -- No layout de toque o proprio botao e o acionador, entao nao mostramos glifo de bind.
        local bind = (not isTouch) and getBindIcon(slotInfo) or nil
        local itemName = slotInfo.Current and slotInfo.Current.Name or nil

        UI:RenderSlot(slotNumber, itemName, slotInfo.Equipped, bind, isTouch, function()
            toggleSlot(hotbar, slotNumber)
        end)

        local keyCode = slotInfo.Binds[device]
        if not keyCode then continue end

        ContextActionService:BindAction(
            "HotbarSlot" .. slotNumber,
            function(_, inputState)
                if inputState == Enum.UserInputState.Begin then
                    toggleSlot(hotbar, slotNumber)
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
    refreshSlots(self)

    UserInputService.LastInputTypeChanged:Connect(function()
        refreshSlots(self)
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
            refreshSlots(self)
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
    refreshSlots(self)
    print("Removed item from slot " .. slotNumber)
end

return Hotbar
