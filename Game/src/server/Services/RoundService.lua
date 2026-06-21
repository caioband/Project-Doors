--!strict
-- RoundService
-- Orquestra o ciclo de rodada e o carregamento de mapas:
--   * Clona um mapa de ServerStorage.Assets.Models.Maps para o slot Workspace.MapInUse.ActiveMap
--   * Sincroniza com os clientes via Comms.Round (MapLoaded / MapReady / RoundState / StartTransition / RoundTimer)
--   * Espera TODOS os players confirmarem (barreira de prontidao) antes de rodar o comportamento
--     server do mapa, garantindo que o behavior so executa quando o mapa esta carregado para todos
--   * Resolve o comportamento de cada mapa por nome em Services.MapBehaviors.<NomeDoMapa>
--   * Conduz o loop Lobby (votacao) -> Carregar mapa -> Rodada ativa -> Descarregar -> Lobby
--
-- Para dar comportamento a um mapa, crie Services/MapBehaviors/<NomeDoMapa>.lua (server) e/ou
-- Controllers/MapBehaviors/<NomeDoMapa>.lua (client) expondo OnLoad(ctx)/OnUnload(ctx).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local ConnectionPlus = require(ReplicatedStorage.Shared.SharedModules.ConnectionPlus)

local RoundService = {}

-- Tempo maximo (s) que a barreira espera todos os clientes confirmarem MapReady (preload
-- concluido) antes de prosseguir mesmo assim (evita travar a rodada se um cliente falhar/lento).
local READY_TIMEOUT = 120
-- Duracao (s) do fade-in (tela escurece): apos esse tempo a tela esta totalmente preta e o
-- servidor teleporta os players. O cliente faz fade-in + fade-out (total = soma dos dois).
local TRANSITION_FADE_IN = 5
local TRANSITION_FADE_OUT = 5
-- Duracao (s) da rodada ativa (5 minutos). O servidor conta esse tempo e replica o restante
-- para os clientes a cada segundo (RoundTimer), que atualizam o Timer da GeneralUis. Ao zerar,
-- o mapa NAO e descarregado (o comportamento pos-rodada sera implementado depois).
local ROUND_DURATION = 300
-- Nome do mapa usado quando nao ha mapeamento especifico para a porta vencedora.
local DEFAULT_MAP = "Office"

-- Mapeamento porta-vencedora -> nome do mapa. Editar para adicionar mapas/portas.
local MapForDoor: { [number]: string } = {
    [1] = "Office",
    [2] = "Office",
}

-- Contexto passado aos modulos de comportamento (server).
export type BehaviorContext = {
    Map: Model,
    MapName: string,
    LoadId: number,
    GetService: (string) -> any,
    Connections: typeof(ConnectionPlus),
}

type Behavior = {
    OnLoad: ((BehaviorContext) -> ())?,
    OnUnload: ((BehaviorContext) -> ())?,
}

-- Estado do mapa atualmente carregado.
local CurrentMap: Model? = nil
local CurrentMapName: string? = nil
local CurrentBehavior: Behavior? = nil
local CurrentContext: BehaviorContext? = nil

-- Identificador incremental de cada carregamento; usado para casar os MapReady recebidos.
local LoadId = 0
-- Players que ja confirmaram prontidao para o LoadId atual.
local ReadyPlayers: { [Player]: boolean } = {}

local MapLoadedRemote: RemoteEvent
local MapReadyRemote: RemoteEvent
local RoundStateRemote: RemoteEvent
local StartTransitionRemote: RemoteEvent
local RoundTimerRemote: RemoteEvent


-- Garante a hierarquia ReplicatedStorage.Comms.Round e os Remotes necessarios.
local function EnsureRemotes()
    local comms = ReplicatedStorage:FindFirstChild("Comms")
    if not comms then
        comms = Instance.new("Folder")
        comms.Name = "Comms"
        comms.Parent = ReplicatedStorage
    end

    local roundFolder = comms:FindFirstChild("Round")
    if not roundFolder then
        roundFolder = Instance.new("Folder")
        roundFolder.Name = "Round"
        roundFolder.Parent = comms
    end

    MapLoadedRemote = roundFolder:FindFirstChild("MapLoaded") :: RemoteEvent
    if not MapLoadedRemote then
        MapLoadedRemote = Instance.new("RemoteEvent")
        MapLoadedRemote.Name = "MapLoaded"
        MapLoadedRemote.Parent = roundFolder
    end

    MapReadyRemote = roundFolder:FindFirstChild("MapReady") :: RemoteEvent
    if not MapReadyRemote then
        MapReadyRemote = Instance.new("RemoteEvent")
        MapReadyRemote.Name = "MapReady"
        MapReadyRemote.Parent = roundFolder
    end

    RoundStateRemote = roundFolder:FindFirstChild("RoundState") :: RemoteEvent
    if not RoundStateRemote then
        RoundStateRemote = Instance.new("RemoteEvent")
        RoundStateRemote.Name = "RoundState"
        RoundStateRemote.Parent = roundFolder
    end

    StartTransitionRemote = roundFolder:FindFirstChild("StartTransition") :: RemoteEvent
    if not StartTransitionRemote then
        StartTransitionRemote = Instance.new("RemoteEvent")
        StartTransitionRemote.Name = "StartTransition"
        StartTransitionRemote.Parent = roundFolder
    end

    RoundTimerRemote = roundFolder:FindFirstChild("RoundTimer") :: RemoteEvent
    if not RoundTimerRemote then
        RoundTimerRemote = Instance.new("RemoteEvent")
        RoundTimerRemote.Name = "RoundTimer"
        RoundTimerRemote.Parent = roundFolder
    end
end


-- Teleporta todos os players para os spawns do mapa (Folder "PlayersSpawns"), garantindo que
-- nenhum spawne em cima de outro: cada player recebe um spawn distinto (round-robin); se houver
-- mais players que spawns, os excedentes recebem um deslocamento lateral para nao colidir.
local function TeleportPlayersToMap(map: Model)
    local spawnsFolder = map:FindFirstChild("PlayersSpawns")
    if not spawnsFolder then
        warn(string.format("[RoundService] Mapa '%s' nao tem PlayersSpawns; players nao teleportados.", tostring(CurrentMapName)))
        return
    end

    local spawns: { BasePart } = {}
    for _, child in ipairs(spawnsFolder:GetChildren()) do
        if child:IsA("BasePart") then
            table.insert(spawns, child)
        end
    end
    if #spawns == 0 then
        return
    end
    -- Ordem deterministica por nome (1,2,3,4...).
    table.sort(spawns, function(a, b)
        return a.Name < b.Name
    end)
    -- Embaralha para variar quem nasce onde a cada rodada.
    for i = #spawns, 2, -1 do
        local j = math.random(1, i)
        spawns[i], spawns[j] = spawns[j], spawns[i]
    end

    local players = Players:GetPlayers()
    for index, player in ipairs(players) do
        local spawnIndex = ((index - 1) % #spawns) + 1
        local overflow = math.floor((index - 1) / #spawns) -- 0 na primeira volta
        local spawnPart = spawns[spawnIndex]

        local character = player.Character
        local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
        if root then
            -- Sobe ~3 studs (altura do HumanoidRootPart) e desloca os excedentes para o lado.
            local cframe = spawnPart.CFrame * CFrame.new(overflow * 4, 3, 0)
            root.CFrame = cframe
        end
    end
end


-- Garante o Folder Workspace.MapInUse (container do mapa ativo e da VotingRoom persistente).
local function GetMapContainer(): Folder
    local container = Workspace:FindFirstChild("MapInUse")
    if not container then
        container = Instance.new("Folder")
        container.Name = "MapInUse"
        container.Parent = Workspace
    end
    return container :: Folder
end


-- Resolve o modulo de comportamento server de um mapa (nil se o mapa nao tiver logica).
local function RequireBehavior(mapName: string): Behavior?
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
        warn(string.format("[RoundService] Falha ao carregar behavior '%s': %s", mapName, tostring(result)))
        return nil
    end
    return result :: Behavior
end


-- Broadcast da fase atual da rodada (para UI/clientes reagirem).
local function SetRoundState(state: string)
    if RoundStateRemote then
        RoundStateRemote:FireAllClients(state)
    end
end


-- Descarrega o mapa atual: roda OnUnload, desconecta tudo (ConnectionPlus) e destroi o slot.
function RoundService:UnloadMap()
    if CurrentBehavior and CurrentBehavior.OnUnload and CurrentContext then
        local ok, err = pcall(CurrentBehavior.OnUnload, CurrentContext)
        if not ok then
            warn(string.format("[RoundService] OnUnload('%s') erro: %s", tostring(CurrentMapName), tostring(err)))
        end
    end

    if CurrentMap then
        ConnectionPlus:DisconnectAll(CurrentMap)
        CurrentMap:Destroy()
    end

    local container = GetMapContainer()
    container:SetAttribute("CurrentMap", nil)
    container:SetAttribute("LoadId", nil)

    CurrentMap = nil
    CurrentMapName = nil
    CurrentBehavior = nil
    CurrentContext = nil
end


-- Espera todos os players atuais confirmarem MapReady para o loadId informado, com timeout.
local function WaitForReadyBarrier(loadId: number)
    local deadline = os.clock() + READY_TIMEOUT

    local function AllReady(): boolean
        for _, player in ipairs(Players:GetPlayers()) do
            if not ReadyPlayers[player] then
                return false
            end
        end
        return true
    end

    while LoadId == loadId and not AllReady() and os.clock() < deadline do
        task.wait(0.1)
    end
end


-- Carrega um mapa: clona o asset para Workspace.MapInUse.ActiveMap, avisa os clientes,
-- espera a barreira de prontidao e entao roda o comportamento server do mapa.
-- Retorna o Model carregado (ou nil em caso de erro).
function RoundService:LoadMap(mapName: string): Model?
    -- Limpa o mapa anterior antes de carregar o novo.
    if CurrentMap then
        self:UnloadMap()
    end

    local mapsFolder = ServerStorage:FindFirstChild("Assets")
    mapsFolder = mapsFolder and mapsFolder:FindFirstChild("Models")
    mapsFolder = mapsFolder and mapsFolder:FindFirstChild("Maps")
    local template = mapsFolder and mapsFolder:FindFirstChild(mapName)

    if not template or not template:IsA("Model") then
        warn(string.format("[RoundService] Mapa '%s' nao encontrado em ServerStorage.Assets.Models.Maps", mapName))
        return nil
    end

    -- Clona preservando o WorldPivot original (mapas autorados em coordenadas de mundo).
    local map = template:Clone()
    map.Name = "ActiveMap"

    local container = GetMapContainer()

    LoadId += 1
    local thisLoadId = LoadId
    ReadyPlayers = {}

    map.Parent = container
    container:SetAttribute("CurrentMap", mapName)
    container:SetAttribute("LoadId", thisLoadId)

    CurrentMap = map
    CurrentMapName = mapName

    -- Avisa todos os clientes para resolverem o mapa e PRELOADAREM os assets do mapa.
    SetRoundState("Loading")
    MapLoadedRemote:FireAllClients(mapName, thisLoadId)

    -- Barreira: so prossegue quando todos terminarem o preload (ou no timeout). Enquanto isso,
    -- cada cliente mostra o progresso e "aguardando outros jogadores" no texto do timer.
    WaitForReadyBarrier(thisLoadId)

    -- Se outro LoadMap aconteceu durante a espera, aborta este.
    if LoadId ~= thisLoadId or CurrentMap ~= map then
        return map
    end

    -- Todos prontos: inicia a transicao de tela (fade) nos clientes. Quando a tela estiver
    -- totalmente preta (apos o fade-in), teleporta todos os players para os spawns do mapa.
    StartTransitionRemote:FireAllClients(thisLoadId, TRANSITION_FADE_IN, TRANSITION_FADE_OUT)
    task.wait(TRANSITION_FADE_IN)

    if LoadId ~= thisLoadId or CurrentMap ~= map then
        return map
    end

    TeleportPlayersToMap(map)

    -- Resolve e roda o comportamento server do mapa.
    local behavior = RequireBehavior(mapName)
    CurrentBehavior = behavior

    if behavior then
        local context: BehaviorContext = {
            Map = map,
            MapName = mapName,
            LoadId = thisLoadId,
            GetService = self.GetService,
            Connections = ConnectionPlus,
        }
        CurrentContext = context

        if behavior.OnLoad then
            local ok, err = pcall(behavior.OnLoad, context)
            if not ok then
                warn(string.format("[RoundService] OnLoad('%s') erro: %s", mapName, tostring(err)))
            end
        end
    end

    return map
end


-- Handler de MapReady: registra a confirmacao do player para o LoadId atual.
local function OnMapReady(player: Player, loadId: any)
    if typeof(loadId) ~= "number" or loadId ~= LoadId then
        return
    end
    ReadyPlayers[player] = true
end


-- Geracao do timer da rodada: incrementada para invalidar contagens anteriores.
local RoundTimerGeneration = 0

-- Conduz a contagem regressiva da rodada (ROUND_DURATION s), transmitindo o tempo restante a
-- cada segundo para os clientes (que atualizam o Timer da GeneralUis). Bloqueia ate o cronometro
-- chegar a zero. Ao zerar, NAO descarrega o mapa: o comportamento pos-rodada sera implementado
-- depois. Aborta se o mapa for trocado/descarregado (LoadId/CurrentMap mudarem).
local function RunRoundTimer(loadId: number)
    RoundTimerGeneration += 1
    local generation = RoundTimerGeneration
    local endsAt = os.clock() + ROUND_DURATION

    while generation == RoundTimerGeneration and LoadId == loadId and CurrentMap do
        local remaining = math.max(0, math.ceil(endsAt - os.clock()))
        RoundTimerRemote:FireAllClients(remaining)
        if remaining <= 0 then
            break
        end
        task.wait(1)
    end
end


-- Loop principal da rodada: Lobby (votacao) -> Carregar mapa -> Rodada -> Descarregar.
function RoundService:RunRoundLoop()
    local VoteService = self.GetService("VoteService")

    while true do
        -- Fase Lobby: reinicia a votacao e espera os players votarem.
        SetRoundState("Lobby")
        if VoteService and VoteService.ResetVotation then
            VoteService:ResetVotation()
        end

        -- Espera a votacao iniciar (algum player aciona o botao), com um teto de seguranca.
        local waitStart = os.clock()
        while VoteService and VoteService.IsVotingActive and not VoteService:IsVotingActive() do
            if os.clock() - waitStart > 300 then
                break
            end
            task.wait(0.5)
        end

        -- Aguarda o VoteService conduzir a contagem e concluir a votacao (fonte unica do tempo).
        while VoteService and VoteService.IsVotingActive and VoteService:IsVotingActive() do
            task.wait(0.25)
        end

        -- Apura o vencedor e escolhe o mapa.
        local winningDoor = 1
        if VoteService and VoteService.TallyWinner then
            winningDoor = VoteService:TallyWinner() or 1
        end
        local mapName = MapForDoor[winningDoor] or DEFAULT_MAP

        -- Fase de carregamento + rodada ativa.
        self:LoadMap(mapName)
        SetRoundState("Active")

        -- Conta os 5 minutos da rodada, replicando o tempo restante para os clientes (que
        -- atualizam o Timer da GeneralUis). Bloqueia ate o cronometro chegar a zero.
        RunRoundTimer(LoadId)

        -- Timer chegou a zero: por enquanto o mapa permanece carregado e a rodada nao recicla.
        -- TODO(pos-rodada): tratar o fim do timer aqui (descarregar mapa, nova votacao, etc.).
        break
    end
end


function RoundService:Init()
    EnsureRemotes()
end


function RoundService:Start()
    MapReadyRemote.OnServerEvent:Connect(OnMapReady)

    Players.PlayerRemoving:Connect(function(player)
        ReadyPlayers[player] = nil
    end)

    -- Late-joiners: se ha um mapa ativo, manda o MapLoaded individual (sem bloquear a barreira
    -- ja resolvida da rodada em andamento).
    Players.PlayerAdded:Connect(function(player)
        if CurrentMapName then
            MapLoadedRemote:FireClient(player, CurrentMapName, LoadId)
        end
    end)

    task.spawn(function()
        self:RunRoundLoop()
    end)
end


return RoundService
