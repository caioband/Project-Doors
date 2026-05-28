local Players = game:GetService("Players")

Players.CharacterAutoLoads = false

local servicesFolder = script
local services = {}

for i,v in pairs(servicesFolder:GetChildren()) do
    if v:IsA("ModuleScript") then
        local serviceName = v.Name
        local serviceModule = require(v)
        services[serviceName] = serviceModule
    end
end

return services
