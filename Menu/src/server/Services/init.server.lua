local Players = game:GetService("Players")

-- Players.CharacterAutoLoads = false

local servicesFolder = script
local services = {}

local function GetService(serviceName)
    return services[serviceName]
end

for _, child in ipairs(servicesFolder:GetChildren()) do
    if child:IsA("ModuleScript") then
        local service = require(child)

        services[child.Name] = service
    end
end

for _, service in pairs(services) do
    service.GetService = GetService

    if type(service.Init) == "function" then
        service:Init()
    end
end

for serviceName, service in pairs(services) do
    if type(service.Start) == "function" then
        service:Start()
        continue
    end

    warn(string.format("[Services] '%s' does not implement Start()", serviceName))
end


