local UI = {}
local SlotsPositions = {
    [1] = {SlotPosition = UDim2.fromScale(0.502, 0.197), BindIconPosition = UDim2.fromScale(0.5, 0.5)},
    [2] = {SlotPosition = UDim2.fromScale(0.806, 0.5), BindIconPosition = UDim2.fromScale(0.6, 0.5)},
    [3] = {SlotPosition = UDim2.fromScale(0.502, 0.805), BindIconPosition = UDim2.fromScale(0.7, 0.5)},
    [4] = {SlotPosition = UDim2.fromScale(0.202, 0.5), BindIconPosition = UDim2.fromScale(0.8, 0.5)},    
}

local ItemIcons = {
    ["Flashlight"] = "rbxassetid://1234567890", 
}


local PlayerGui = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
local HotbarUI = PlayerGui:WaitForChild("SharedGuis"):WaitForChild("Hotbar")
local HotbarImage = HotbarUI.Frame:WaitForChild("ImageLabel")


function UI:Render()
    HotbarUI.Enabled = true
end

function UI:AddSlot(slotNumber: number, BindIcon: string, itemIcon: string)
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
        slot.ItemIcon.Visible = true
        slot.ItemIcon.Image = ItemIcons[itemIcon]
    end
    
    if not BindIcon then 
        slot.BindIcon.Visible = false
    else
        slot.BindIcon.Visible = true
        slot.BindIcon.Image = BindIcon
    end
    
end

return UI 