--!strict
-- RoundService
-- Orquestra o ciclo de rodada e o carregamento de mapas:
--   * Clona um mapa de ServerStorage.Assets.Models.Maps para o slot Workspace.MapInUse.ActiveMap
--   * Sincroniza com os clientes via Comms.Round (MapLoaded / MapReady / RoundState / StartTransition / RoundTimer)
--   * Espera TODOS os players confirmarem (barreira de prontidao) antes de rodar o comportamento
--     server do mapa, garantindo que o behavior so executa quando o mapa esta carregado para todos
--   * Resolve o comportamento de cada mapa por nome em Services.MapBehaviors.<NomeDoMapa>
--   * Conduz o loop Lobby (votacao) -> Carregar mapa -> Rodada ativa -> Fuga (EscapeArea) ->
--     Descarregar -> Lobby. Ao zerar o timer da rodada, a fase de fuga liga os billboards da
--     Folder ctx.Map.EscapeArea e os players tem um countdown para entrar numa area antes de
--     serem teleportados de volta para a VotingRoom (Workspace.SpawnLocation). Ver RunEscapePhase.
--
-- Para dar comportamento a um mapa, crie Services/MapBehaviors/<NomeDoMapa>.lua (server) e/ou
-- Controllers/MapBehaviors/<NomeDoMapa>.lua (client) expondo OnLoad(ctx)/OnUnload(ctx). O behavior
-- server pode expor tambem OnRoundEnd(ctx) (timer zera / fuga liberada) e OnEscapeEnd(ctx) (o
-- countdown da fuga acaba; o mapa cuida do teleporte de volta para a VotingRoom).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local ConnectionPlus = require(ReplicatedStorage.Shared.SharedModules.ConnectionPlus)
local TimerFormat = require(ReplicatedStorage.Shared.SharedModules.TimerFormat)

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
-- inicia a fase de fuga (EscapeArea) em vez de manter o mapa carregado.
local ROUND_DURATION = 300

-- Fase de fuga (EscapeArea): ao zerar o timer da rodada, os players tem um tempo para entrar em
-- uma das partes da Folder ctx.Map.EscapeArea antes de serem teleportados de volta para a
-- VotingRoom (e o mapa ser descarregado). Isso e padrao para todo mapa que tiver a Folder.
--   * O countdown so COMECA quando o primeiro player elegivel (vivo) entra numa area (ate la, o
--     billboard mostra ESCAPE_COUNTDOWN parado).
--   * Quando TODOS os players elegiveis estao dentro (o que inclui o caso solo), o countdown cai
--     para ESCAPE_FAST_COUNTDOWN. O deadline so ENCURTA (um player sair nao volta para 30s).
--   * ESCAPE_MAX_WAIT e um teto de seguranca: encerra a fuga mesmo se ninguem entrar (ex.: todos
--     mortos/AFK), evitando travar a rodada.
local ESCAPE_COUNTDOWN = 30
local ESCAPE_FAST_COUNTDOWN = 5
local ESCAPE_MAX_WAIT = 90
-- Intervalo (s) de deteccao/atualizacao da fase de fuga (billboard + posicoes dos players).
local ESCAPE_TICK = 0.2
-- Folga (studs) somada a meia-extensao da area para a checagem "player dentro" ser tolerante.
local ESCAPE_AREA_PADDING = 1

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
    -- Chamado quando o timer da rodada zera, ANTES da fase de fuga comecar (o momento em que os
    -- players precisam correr para a EscapeArea / "area de escape liberada"). Opcional; use para
    -- reacoes por-mapa ao inicio da fuga. Rodado sob pcall pelo RoundService.
    OnRoundEnd: ((BehaviorContext) -> ())?,
    -- Chamado quando o COUNTDOWN da fuga acaba (tempo de chegar na EscapeArea esgotado). O mapa
    -- cuida do desfecho: teleportar os players de volta para a VotingRoom (ex.: Office fecha as
    -- portas do elevador, faz o fade e teleporta no meio). DEVE bloquear ate concluir o teleporte
    -- (o RoundService descarrega o mapa logo depois). Se ausente, o RoundService faz a transicao +
    -- teleporte generico. Rodado sob pcall; em erro ha uma rede de seguranca de teleporte.
    OnEscapeEnd: ((BehaviorContext) -> ())?,
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
local EscapeTransitionRemote: RemoteEvent


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

    EscapeTransitionRemote = roundFolder:FindFirstChild("EscapeTransition") :: RemoteEvent
    if not EscapeTransitionRemote then
        EscapeTransitionRemote = Instance.new("RemoteEvent")
        EscapeTransitionRemote.Name = "EscapeTransition"
        EscapeTransitionRemote.Parent = roundFolder
    end
end


-- Broadcast da fase atual da rodada (para UI/clientes reagirem).
local function SetRoundState(state: string)
    if RoundStateRemote then
        RoundStateRemote:FireAllClients(state)
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


-- Teleporta TODOS os players de volta para a VotingRoom (o SpawnLocation persistente em Workspace)
-- ao fim da fase de fuga, antes de descarregar o mapa. Inclui mortos/downed: seus personagens
-- ainda existem e cairiam no vazio quando o mapa fosse destruido. Distribui os players numa grade
-- ao redor do spawn para nao empilhar. Nao revive ninguem (o sistema de vidas/respawn cuida disso).
local function TeleportPlayersToVotingRoom()
    local spawn = Workspace:FindFirstChild("SpawnLocation")
    if not spawn or not spawn:IsA("BasePart") then
        warn("[RoundService] Workspace.SpawnLocation nao encontrado; players nao voltaram a VotingRoom.")
        return
    end

    for index, player in ipairs(Players:GetPlayers()) do
        local character = player.Character
        local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
        if root then
            -- Grade 3-por-linha ao redor do spawn (4 studs de espacamento) + 3 de altura.
            local col = (index - 1) % 3
            local row = math.floor((index - 1) / 3)
            root.CFrame = spawn.CFrame * CFrame.new((col - 1) * 4, 3, row * 4)
        end
    end
end


-- Coleta as partes de captura da fase de fuga (BaseParts diretas da Folder EscapeArea do mapa).
local function CollectEscapeAreas(map: Model): { BasePart }
    local folder = map:FindFirstChild("EscapeArea")
    local areas: { BasePart } = {}
    if not folder then
        return areas
    end
    for _, child in ipairs(folder:GetChildren()) do
        if child:IsA("BasePart") then
            table.insert(areas, child)
        end
    end
    return areas
end


-- True se o ponto esta dentro da caixa (orientada) de alguma area de fuga (com folga).
local function IsInsideAnyArea(position: Vector3, areas: { BasePart }): boolean
    for _, area in ipairs(areas) do
        local local_ = area.CFrame:PointToObjectSpace(position)
        local half = area.Size * 0.5
        if math.abs(local_.X) <= half.X + ESCAPE_AREA_PADDING
            and math.abs(local_.Y) <= half.Y + ESCAPE_AREA_PADDING
            and math.abs(local_.Z) <= half.Z + ESCAPE_AREA_PADDING then
            return true
        end
    end
    return false
end


-- Liga (ou desliga) o BillboardGui de cada area de fuga e atualiza os labels PlayerCount/Countdown.
-- O billboard e autorado no mapa (server-owned): setar .Enabled/.Text aqui replica para todos os
-- clientes automaticamente, entao a fase de fuga nao precisa de logica no client.
local function UpdateEscapeBillboards(areas: { BasePart }, enabled: boolean, countText: string?, countdownText: string?)
    for _, area in ipairs(areas) do
        local billboard = area:FindFirstChildWhichIsA("BillboardGui")
        if billboard then
            billboard.Enabled = enabled
            local playerCount = billboard:FindFirstChild("PlayerCount")
            local countdown = billboard:FindFirstChild("Countdown")
            if playerCount and playerCount:IsA("TextLabel") and countText then
                playerCount.Text = countText
            end
            if countdown and countdown:IsA("TextLabel") and countdownText then
                countdown.Text = countdownText
            end
        end
    end
end


-- Conduz a fase de fuga apos o timer da rodada zerar: liga os billboards das areas, conta quantos
-- players elegiveis (vivos) estao dentro e conduz o countdown (30s ao primeiro entrar; 5s quando
-- todos os elegiveis estao dentro, inclusive solo). Ao encerrar (deadline ou teto de seguranca),
-- teleporta todos de volta para a VotingRoom. Bloqueia ate terminar. Aborta se o mapa for
-- trocado/descarregado (LoadId/CurrentMap mudarem).
local function RunEscapePhase(loadId: number)
    local map = CurrentMap
    if not map then
        return
    end

    local areas = CollectEscapeAreas(map)
    if #areas == 0 then
        warn(string.format("[RoundService] Mapa '%s' sem EscapeArea; pulando fase de fuga.", tostring(CurrentMapName)))
        return
    end

    SetRoundState("Escape")

    local startClock = os.clock()
    local countdownActive = false
    local deadline = 0

    while LoadId == loadId and CurrentMap == map do
        -- Conta players elegiveis (personagem vivo) e quantos deles estao dentro de alguma area.
        local totalEligible = 0
        local insideEligible = 0
        for _, player in ipairs(Players:GetPlayers()) do
            local character = player.Character
            local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
            if root and character:GetAttribute("State") == "Alive" then
                totalEligible += 1
                if IsInsideAnyArea(root.Position, areas) then
                    insideEligible += 1
                end
            end
        end

        local now = os.clock()

        -- O countdown comeca quando o primeiro player elegivel entra numa area.
        if not countdownActive and insideEligible >= 1 then
            countdownActive = true
            deadline = now + ESCAPE_COUNTDOWN
        end

        -- Todos os elegiveis dentro (inclui o caso solo) -> acelera para 5s. So encurta o deadline.
        if countdownActive and totalEligible >= 1 and insideEligible >= totalEligible then
            deadline = math.min(deadline, now + ESCAPE_FAST_COUNTDOWN)
        end

        local remaining = if countdownActive then math.max(0, deadline - now) else ESCAPE_COUNTDOWN
        UpdateEscapeBillboards(
            areas,
            true,
            string.format("%d/%d", insideEligible, totalEligible),
            TimerFormat.Format(remaining)
        )

        -- Encerra ao esgotar o countdown ou ao atingir o teto de seguranca da fase.
        if countdownActive and now >= deadline then
            break
        end
        if now - startClock >= ESCAPE_MAX_WAIT then
            break
        end

        task.wait(ESCAPE_TICK)
    end

    -- Se outro load aconteceu durante a fuga, aborta sem teleportar (o novo load ja reposicionou).
    if LoadId ~= loadId or CurrentMap ~= map then
        return
    end

    -- Countdown encerrado: o MAPA cuida do desfecho (fechar portas, fade, teleporte) via OnEscapeEnd
    -- e DEVE bloquear ate concluir o teleporte. Sem hook, faz a transicao + teleporte generico.
    if CurrentBehavior and CurrentBehavior.OnEscapeEnd and CurrentContext then
        local ok, err = pcall(CurrentBehavior.OnEscapeEnd, CurrentContext)
        if not ok then
            warn(string.format("[RoundService] OnEscapeEnd('%s') erro: %s", tostring(CurrentMapName), tostring(err)))
            -- Rede de seguranca: garante que ninguem fique no mapa prestes a ser destruido.
            TeleportPlayersToVotingRoom()
        end
    else
        RoundService:PlayEscapeTransition(function()
            TeleportPlayersToVotingRoom()
        end)
    end
end


-- Metodo publico (para os MapBehaviors, via ctx.GetService): teleporta todos os players de volta
-- para a VotingRoom. Usado pelo OnEscapeEnd do mapa no meio da transicao (tela preta).
function RoundService:TeleportPlayersToVotingRoom()
    TeleportPlayersToVotingRoom()
end


-- Metodo publico (para os MapBehaviors): dispara a transicao de tela (fade in -> preto -> fade out)
-- nos clientes, reusando a mesma UI da transicao votacao->mapa (mas sem tocar os InitialSounds do
-- mapa, pois estamos indo para a VotingRoom). Espera o fade-in e entao chama atBlack (tela preta) —
-- e onde o mapa teleporta os players. Retorna apos o atBlack (o fade-out segue nos clientes).
function RoundService:PlayEscapeTransition(atBlack: (() -> ())?)
    if EscapeTransitionRemote then
        EscapeTransitionRemote:FireAllClients(TRANSITION_FADE_IN, TRANSITION_FADE_OUT)
    end
    task.wait(TRANSITION_FADE_IN)
    if atBlack then
        atBlack()
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
-- Instante (os.clock) em que a rodada ativa termina. Fica num upvalue para o SetRoundTime poder
-- encurtar/estender a rodada em andamento (ex.: comando admin para testar a fuga). nil sem rodada.
local RoundEndsAt: number? = nil

-- Conduz a contagem regressiva da rodada (ROUND_DURATION s), transmitindo o tempo restante a
-- cada segundo para os clientes (que atualizam o Timer da GeneralUis). Bloqueia ate o cronometro
-- chegar a zero. Ao zerar, o RunRoundLoop inicia a fase de fuga (EscapeArea). Aborta se o mapa
-- for trocado/descarregado (LoadId/CurrentMap mudarem). Le RoundEndsAt a cada tick, entao uma
-- mudanca via SetRoundTime vale no proximo tick (<=1s).
local function RunRoundTimer(loadId: number)
    RoundTimerGeneration += 1
    local generation = RoundTimerGeneration
    RoundEndsAt = os.clock() + ROUND_DURATION

    while generation == RoundTimerGeneration and LoadId == loadId and CurrentMap do
        local remaining = math.max(0, math.ceil((RoundEndsAt or os.clock()) - os.clock()))
        RoundTimerRemote:FireAllClients(remaining)
        if remaining <= 0 then
            break
        end
        task.wait(1)
    end

    if generation == RoundTimerGeneration then
        RoundEndsAt = nil
    end
end


-- Ajusta o tempo RESTANTE da rodada ativa, em segundos (ex.: comando admin para testar a fase de
-- fuga sem esperar os 5 min). So age se houver uma rodada rodando; a mudanca vale no proximo tick
-- do timer (<=1s). 0 encerra a rodada quase imediatamente. Retorna (ok, mensagem).
function RoundService:SetRoundTime(seconds: number): (boolean, string)
    if type(seconds) ~= "number" or seconds ~= seconds or seconds < 0 then
        return false, "Tempo invalido: use um numero de segundos >= 0."
    end
    if not RoundEndsAt or not CurrentMap then
        return false, "Nenhuma rodada ativa no momento (so vale durante a rodada, nao na votacao/fuga)."
    end
    RoundEndsAt = os.clock() + seconds
    return true, string.format("Tempo restante da rodada ajustado para %d segundo(s).", math.floor(seconds))
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
        local roundLoadId = LoadId
        RunRoundTimer(roundLoadId)

        -- Timer zerou: avisa o comportamento do mapa (hook OnRoundEnd, ex.: parar NPCs) e entao
        -- conduz a fase de fuga (EscapeArea) — os players correm para uma area antes de serem
        -- teleportados de volta para a VotingRoom. So age se este load ainda for o atual.
        if LoadId == roundLoadId and CurrentMap then
            if CurrentBehavior and CurrentBehavior.OnRoundEnd and CurrentContext then
                local ok, err = pcall(CurrentBehavior.OnRoundEnd, CurrentContext)
                if not ok then
                    warn(string.format("[RoundService] OnRoundEnd('%s') erro: %s", tostring(CurrentMapName), tostring(err)))
                end
            end

            RunEscapePhase(roundLoadId)

            -- Fim da fuga: descarrega o mapa e recicla (o topo do loop volta para o Lobby/votacao).
            if LoadId == roundLoadId then
                self:UnloadMap()
            end
        end
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
