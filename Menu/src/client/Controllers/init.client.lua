local ReplicatedFirst = game:GetService("ReplicatedFirst")

while not ReplicatedFirst:GetAttribute("Loaded") do
    ReplicatedFirst:GetAttributeChangedSignal("Loaded"):Wait()
end

for i,v in pairs(script:GetChildren()) do
    if v:IsA("ModuleScript") then
        local moduleName = v.Name
        local module = require(v)
        if not module.Start then
            warn("Controller " .. moduleName .. " does not have a Start function.")
        else
            module:Start()
        end
    end
end