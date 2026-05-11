local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Knit = require(Packages:WaitForChild("Knit"))
local Services = script.Parent:WaitForChild("Services")

for _, moduleScript in Services:GetChildren() do
	if moduleScript:IsA("ModuleScript") then
		require(moduleScript)
	end
end

Knit.Start():catch(function(err)
	warn("[Knit] Failed to start server:", err)
end)
