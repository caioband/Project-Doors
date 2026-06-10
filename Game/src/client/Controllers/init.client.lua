local ReplicatedFirst = game:GetService("ReplicatedFirst")

while not ReplicatedFirst:GetAttribute("Loaded") do
	ReplicatedFirst:GetAttributeChangedSignal("Loaded"):Wait()
end

local Controllers = {}

local function GetController(controllerName)
	return Controllers[controllerName]
end


for _, child in ipairs(script:GetChildren()) do
	if child:IsA("ModuleScript") then
		local controller = require(child)

		Controllers[child.Name] = controller
	end
end


for _, controller in pairs(Controllers) do
	controller.GetController = GetController
end


for name, controller in pairs(Controllers) do
	if type(controller.Start) == "function" then
		controller:Start()
	end
end