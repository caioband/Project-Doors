local Hotbar = {}

local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")

local UI = require(script.UI)
local DeviceController = require(script.Parent.DeviceController)

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

local function bindSlots(hotbar)
    for slotNumber in pairs(hotbar.Slots) do
        ContextActionService:UnbindAction("HotbarSlot" .. slotNumber)
    end

    local device = DeviceController:GetDevice()

    for slotNumber, slotInfo in pairs(hotbar.Slots) do
        local keyCode = slotInfo.Binds[device]
        if not keyCode then continue end

        ContextActionService:BindAction(
            "HotbarSlot" .. slotNumber,
            function(_, inputState)
                if inputState == Enum.UserInputState.Begin then
                    hotbar:Equip(slotNumber)
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
    print("Slot " .. slotNumber .. " equipped")
end

function Hotbar:Unequip(slotNumber: number)
    local slot = self.Slots[slotNumber]
    if not slot then
        warn("Invalid hotbar slot: " .. tostring(slotNumber))
        return
    end

    slot.Equipped = false
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
