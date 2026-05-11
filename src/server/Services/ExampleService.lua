local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Knit = require(Packages:WaitForChild("Knit"))

local ExampleService = Knit.CreateService({
	Name = "ExampleService",
	Client = {},
})

function ExampleService:KnitInit()
	self._serverStartedAt = os.clock()
end

function ExampleService.Client:GetServerUptime(player)
	return os.clock() - self.Server._serverStartedAt
end

return ExampleService
