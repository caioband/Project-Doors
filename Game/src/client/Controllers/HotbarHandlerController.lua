local HotbarHandler = {}
local Hotbar = require(game:GetService("ReplicatedStorage").Shared.SharedModules.Hotbar)

function HotbarHandler:Start()
    Hotbar:Start()
end

return HotbarHandler