local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Knit = require(Packages:WaitForChild("Knit"))
local Controllers = script.Parent:WaitForChild("Controllers")

for _, moduleScript in Controllers:GetChildren() do
	if moduleScript:IsA("ModuleScript") then
		require(moduleScript)
	end
end

Knit.Start():catch(function(err)
	warn("[Knit] Failed to start client:", err)
end)
