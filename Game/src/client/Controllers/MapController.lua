-- MapController
-- Contraparte client do RoundService:
--   * Escuta Comms.Round.MapLoaded (mapName, loadId)
--   * Resolve o mapa carregado em Workspace.MapInUse.ActiveMap (espera replicacao/atributos)
--   * Roda o comportamento client do mapa (Controllers.MapBehaviors.<NomeDoMapa>)
--   * Confirma ao servidor via MapReady para liberar a barreira de prontidao
--
-- Para dar comportamento client a um mapa, crie Controllers/MapBehaviors/<NomeDoMapa>.lua
-- expondo OnLoad(ctx)/OnUnload(ctx). ctx tem Map, MapName, LoadId, GetController, Connections.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local Workspace = game:GetService("Workspace")

local ConnectionPlus = require(ReplicatedStorage.Shared.SharedModules.ConnectionPlus)
local Preloader = require(ReplicatedFirst:WaitForChild("SharedModulesFirst"):WaitForChild("Preloader"))

local MapController = {}

local MapLoadedRemote: RemoteEvent
local MapReadyRemote: RemoteEvent
local StartTransitionRemote: RemoteEvent

-- Estado do mapa atualmente ativo no cliente.
local CurrentMap: Model? = nil
local CurrentBehavior: any = nil
local CurrentContext: any = nil
-- Ultimo LoadId processado (descarta eventos fora de ordem).
local ActiveLoadId = 0


-- Atualiza o texto de status mostrado no Timer da Vote GUI (via VoteController), para o player
-- saber o que o sistema esta fazendo durante o carregamento (sem dar impressao de bug).
local function SetStatus(text: string)
    local getController = MapController.GetController
    local voteController = getController and getController("VoteController")
    if voteController and voteController.SetTimerText then
        voteController:SetTimerText(text)
    end
end


-- Preloada os assets do mapa usando o modulo compartilhado Preloader, atualizando o status
-- com o progresso. Bloqueia ate terminar.
local function PreloadMap(map: Model)
    local assets = map:GetDescendants()
    local total = #assets
    if total == 0 then
        return
    end

    local preloader = Preloader.new()
    preloader:AddAssetsToPreload(assets)

    local loaded = 0
    local conn = preloader.SectionAssetLoaded:Connect(function()
        loaded += 1
        SetStatus(string.format("Loading map... %d%%", math.floor((loaded / total) * 100)))
    end)

    preloader:PreloadAssets()

    conn:Disconnect()
    preloader:Destroy()
end


-- Resolve o modulo de comportamento client de um mapa (nil se nao houver).
local function RequireBehavior(mapName: string): any
    local folder = script.Parent:FindFirstChild("MapBehaviors")
    if not folder then
        return nil
    end

    local module = folder:FindFirstChild(mapName)
    if not module or not module:IsA("ModuleScript") then
        return nil
    end

    local ok, result = pcall(require, module)
    if not ok then
        warn(string.format("[MapController] Falha ao carregar behavior '%s': %s", mapName, tostring(result)))
        return nil
    end
    return result
end


-- Descarrega o comportamento client atual (OnUnload + desconecta conexoes).
local function UnloadCurrent()
    if CurrentBehavior and CurrentBehavior.OnUnload and CurrentContext then
        local ok, err = pcall(CurrentBehavior.OnUnload, CurrentContext)
        if not ok then
            warn(string.format("[MapController] OnUnload erro: %s", tostring(err)))
        end
    end
    if CurrentMap then
        ConnectionPlus:DisconnectAll(CurrentMap)
    end
    CurrentMap = nil
    CurrentBehavior = nil
    CurrentContext = nil
end


-- Espera o slot ActiveMap aparecer e o atributo CurrentMap casar com o mapName/loadId.
local function ResolveMap(mapName: string, loadId: number): Model?
    local container = Workspace:WaitForChild("MapInUse", 30)
    if not container then
        return nil
    end

    -- Espera o atributo bater (replicacao de atributos pode chegar separada do filho).
    local deadline = os.clock() + 30
    while os.clock() < deadline do
        if loadId ~= ActiveLoadId then
            -- Um MapLoaded mais novo chegou; aborta este.
            return nil
        end
        local active = container:FindFirstChild("ActiveMap")
        if active and active:IsA("Model") and container:GetAttribute("CurrentMap") == mapName then
            return active
        end
        task.wait(0.1)
    end
    return nil
end


-- Handler de MapLoaded: resolve o mapa, roda o behavior client e confirma prontidao.
local function OnMapLoaded(mapName: string, loadId: number)
    if typeof(mapName) ~= "string" or typeof(loadId) ~= "number" then
        return
    end

    ActiveLoadId = loadId
    UnloadCurrent()

    SetStatus("Loading map...")

    local map = ResolveMap(mapName, loadId)
    if not map then
        -- Mesmo sem resolver, confirma para nao travar a barreira do servidor.
        MapReadyRemote:FireServer(loadId)
        return
    end

    CurrentMap = map

    -- Preloada os assets do mapa (com progresso no status) antes de confirmar prontidao.
    PreloadMap(map)
    if loadId ~= ActiveLoadId then
        return
    end

    local behavior = RequireBehavior(mapName)
    CurrentBehavior = behavior

    if behavior then
        local context = {
            Map = map,
            MapName = mapName,
            LoadId = loadId,
            GetController = MapController.GetController,
            Connections = ConnectionPlus,
        }
        CurrentContext = context

        if behavior.OnLoad then
            local ok, err = pcall(behavior.OnLoad, context)
            if not ok then
                warn(string.format("[MapController] OnLoad('%s') erro: %s", mapName, tostring(err)))
            end
        end
    end

    -- Confirma prontidao: libera a barreira do servidor quando todos terminarem.
    MapReadyRemote:FireServer(loadId)

    -- Enquanto o servidor espera os demais, avisa que estamos aguardando os outros jogadores.
    SetStatus("Waiting for other players...")
end


function MapController:Start()
    local comms = ReplicatedStorage:WaitForChild("Comms")
    local roundFolder = comms:WaitForChild("Round")
    MapLoadedRemote = roundFolder:WaitForChild("MapLoaded")
    MapReadyRemote = roundFolder:WaitForChild("MapReady")
    StartTransitionRemote = roundFolder:WaitForChild("StartTransition")

    MapLoadedRemote.OnClientEvent:Connect(OnMapLoaded)

    -- Todos prontos: o servidor manda iniciar a transicao de tela (fade). A VoteController cria
    -- o frame preto temporario e faz o fade in/out; o servidor teleporta no meio (tela preta).
    StartTransitionRemote.OnClientEvent:Connect(function(loadId, fadeIn, fadeOut)
        if loadId ~= ActiveLoadId then
            return
        end
        local getController = MapController.GetController
        local voteController = getController and getController("VoteController")
        if voteController and voteController.PlayTransition then
            voteController:PlayTransition(fadeIn, fadeOut)
        end
    end)
end


return MapController
