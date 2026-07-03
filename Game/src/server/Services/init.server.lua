local Players = game:GetService("Players")

-- Players.CharacterAutoLoads = false

local servicesFolder = script
local services = {}

local function GetService(serviceName)
    return services[serviceName]
end

-- Carrega todos os modulos de Service. Cada require e ISOLADO: se um modulo falhar ao carregar,
-- os demais ainda sao registrados (senao um unico erro derrubaria todos os Services).
for _, child in ipairs(servicesFolder:GetChildren()) do
    if child:IsA("ModuleScript") then
        local ok, service = pcall(require, child)
        if ok then
            services[child.Name] = service
        else
            warn(string.format("[Services] Falha ao carregar '%s': %s", child.Name, tostring(service)))
        end
    end
end

-- Injeta o GetService e roda o Init de cada Service, ISOLADAMENTE. Sem o isolamento, um Init/Start
-- que erra abortaria o loop e PULARIA todos os Services seguintes (a ordem de `pairs` varia por
-- boot, entao a falha seria intermitente) — foi o que deixava o NPCService:Start sem rodar e os
-- NPCs parados (Heartbeat nunca conectava). Cada falha e logada com traceback e nao afeta os outros.
for name, service in pairs(services) do
    service.GetService = GetService

    if type(service.Init) == "function" then
        local ok, err = xpcall(function()
            service:Init()
        end, debug.traceback)
        if not ok then
            warn(string.format("[Services] '%s':Init() falhou: %s", name, tostring(err)))
        end
    end
end

for name, service in pairs(services) do
    if type(service.Start) == "function" then
        local ok, err = xpcall(function()
            service:Start()
        end, debug.traceback)
        if not ok then
            warn(string.format("[Services] '%s':Start() falhou: %s", name, tostring(err)))
        end
    else
        warn(string.format("[Services] '%s' does not implement Start()", name))
    end
end
