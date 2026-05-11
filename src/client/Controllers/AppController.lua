local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Knit = require(Packages:WaitForChild("Knit"))
local Roact = require(Packages:WaitForChild("Roact"))

local App = require(script.Parent.Parent.UI.App)

local AppController = Knit.CreateController({
	Name = "AppController",
})

function AppController:KnitStart()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	self._tree = Roact.mount(Roact.createElement(App), playerGui, "App")
	self.ExampleService = Knit.GetService("ExampleService")

	task.spawn(function()
		local ok, uptime = pcall(function()
			return self.ExampleService:GetServerUptime()
		end)

		if ok then
			print(string.format("[ExampleService] Server uptime: %.2fs", uptime))
		end
	end)
end

return AppController
