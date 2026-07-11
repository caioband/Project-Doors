-- MapBehaviors/Office (server)
-- Comportamento server do mapa Office. E carregado pelo RoundService DEPOIS que o mapa esta
-- carregado para TODOS os players (barreira de prontidao).
--
-- Puzzle dos telefones (autoridade no server):
--   * Gera uma senha de 4 digitos por load.
--   * Quando o cliente sinaliza o fim da animacao do monitor (StartPhonePuzzle), liga 1 ou 2
--     telefones aleatorios de ctx.Map.Phones. Com 2, um e a ligacao verdadeira e o outro a falsa.
--   * Telefones selecionados: ProximityPrompt.Enabled = true, BillboardGui.Enabled = true e o
--     RingPlayer (AudioPlayer) tocando (no server -> replica para todos). 30s para atender; senao,
--     +1 erro. Cada RingPlayer esta ligado por Wire a um RingEmitter (AudioEmitter, grupo "General"):
--     os clientes ouvem via AudioListener na Head do personagem (ver AudioListenerController).
--   * Atender (acionar o ProximityPrompt) silencia o telefone e toca o Pick SO para quem atendeu.
--     Se for o verdadeiro: desliga todos os telefones e fala a senha SO para o atendente.
--   * A cada erro (senha errada / timeout) o cliente pede RestartPhonePuzzle: os telefones param
--     e novos sao sorteados (loop). Ao esgotar as tentativas o cliente pede StopPhones (para tudo),
--     toca a animacao de falha e entao StartFailureRing: varios telefones aleatorios tocam (so o
--     som de Ring) por ~30s.
--
-- ctx (BehaviorContext): ver RoundService. ctx.Connections desconecta tudo no UnloadMap.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Office = {}

-- Tempo (s) para atender um telefone antes de +1 erro do puzzle.
local ANSWER_TIME = 30
-- Numero de digitos da senha gerada.
local PASSWORD_LENGTH = 4
-- Quantidade de telefones que tocam (so o Ring) na falha, e por quanto tempo (s).
local FAILURE_RING_COUNT = 10
local FAILURE_RING_TIME = 30
-- Duracao (s) do fechamento das portas do elevador na fase de fuga (OnEscapeEnd).
local DOOR_CLOSE_TIME = 2.2


-- Resolve um caminho aninhado a partir de uma instancia raiz (nil se algum no faltar).
local function resolve(root: Instance?, ...: string): Instance?
    local current = root
    for _, name in { ... } do
        if not current then
            return nil
        end
        current = current:FindFirstChild(name)
    end
    return current
end


-- Fecha as duas portas do elevador simultaneamente: cada porta (BasePart anchored em
-- ctx.Map.Model.Elevator.Doors) recebe um tween de CFrame ate o seu atributo ClosedCFrame. Bloqueia
-- ate as portas terminarem de fechar. No-op silencioso se as portas/atributos nao existirem.
local function closeElevatorDoors(map: Model)
    local doorsModel = resolve(map, "Model", "Elevator", "Doors")
    if not doorsModel then
        warn("[Office:server] Elevator.Doors nao encontrado; portas nao fecharam")
        return
    end

    -- Som do elevador fechando (AudioPlayer autorado dentro do Doors; toca no server -> replica).
    local audio = doorsModel:FindFirstChildWhichIsA("AudioPlayer")
    if audio then
        audio:Play()
    end

    local info = TweenInfo.new(DOOR_CLOSE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
    local closedAny = false
    for _, door in ipairs(doorsModel:GetChildren()) do
        local closedCFrame = door:GetAttribute("ClosedCFrame")
        if door:IsA("BasePart") and typeof(closedCFrame) == "CFrame" then
            TweenService:Create(door, info, { CFrame = closedCFrame }):Play()
            closedAny = true
        end
    end

    if closedAny then
        task.wait(DOOR_CLOSE_TIME)
    end
end

-- Remotes do puzzle do Office (criados sob demanda; persistem entre loads).
local StartPhonePuzzleRemote: RemoteEvent
local RestartPhonePuzzleRemote: RemoteEvent
local StopPhonesRemote: RemoteEvent
local StartFailureRingRemote: RemoteEvent
local SetPasswordRemote: RemoteEvent
local PlayPickSoundRemote: RemoteEvent
local PlayPasswordVoiceRemote: RemoteEvent
local AddPuzzleErrorRemote: RemoteEvent
-- Cliente sinaliza (apos a animacao de falha) para spawnar a Secretary cacadora.
local SpawnSecretaryRemote: RemoteEvent


-- Garante a hierarquia ReplicatedStorage.Comms.Office e os Remotes do puzzle.
local function EnsureRemotes()
    local comms = ReplicatedStorage:FindFirstChild("Comms")
    if not comms then
        comms = Instance.new("Folder")
        comms.Name = "Comms"
        comms.Parent = ReplicatedStorage
    end

    local office = comms:FindFirstChild("Office")
    if not office then
        office = Instance.new("Folder")
        office.Name = "Office"
        office.Parent = comms
    end

    local function ensure(name: string): RemoteEvent
        local remote = office:FindFirstChild(name)
        if not remote then
            remote = Instance.new("RemoteEvent")
            remote.Name = name
            remote.Parent = office
        end
        return remote
    end

    StartPhonePuzzleRemote = ensure("StartPhonePuzzle")
    RestartPhonePuzzleRemote = ensure("RestartPhonePuzzle")
    StopPhonesRemote = ensure("StopPhones")
    StartFailureRingRemote = ensure("StartFailureRing")
    SetPasswordRemote = ensure("SetPassword")
    PlayPickSoundRemote = ensure("PlayPickSound")
    PlayPasswordVoiceRemote = ensure("PlayPasswordVoice")
    AddPuzzleErrorRemote = ensure("AddPuzzleError")
    SpawnSecretaryRemote = ensure("SpawnSecretary")
end


-- Gera uma senha numerica de PASSWORD_LENGTH digitos (cada digito 0-9).
local function generatePassword(): string
    local digits = {}
    for i = 1, PASSWORD_LENGTH do
        digits[i] = tostring(math.random(0, 9))
    end
    return table.concat(digits)
end


-- Embaralha uma lista no lugar (Fisher-Yates).
local function shuffle(t)
    for i = #t, 2, -1 do
        local j = math.random(1, i)
        t[i], t[j] = t[j], t[i]
    end
end


function Office.OnLoad(ctx)
    print(string.format("[Office:server] OnLoad (loadId=%d) - mapa pronto para todos", ctx.LoadId))

    EnsureRemotes()

    -- Secretary: NAO spawna na carga. Fica dormente (escondida) ate o puzzle do monitor falhar.
    -- Quando o cliente termina a animacao de falha, dispara SpawnSecretary e ela e spawnada como
    -- cacadora (estado Hunt) correndo atras de quem falhou. Ver NPCService / SharedModules.NPC.
    local NPCService = ctx.GetService("NPCService")
    NPCService:HideNPCInMap(ctx.Map, "Secretary")

    local secretarySpawned = false
    ctx.Connections:Connect(ctx.Map, "OfficeSpawnSecretary", SpawnSecretaryRemote.OnServerEvent, function(player: Player)
        if secretarySpawned then
            return
        end
        secretarySpawned = true
        NPCService:SpawnHunter(ctx.Map, "Secretary", player)
    end)

    local map = ctx.Map
    local phonesFolder = map:FindFirstChild("Phones")
    local soundsFolder = map:FindFirstChild("Sounds")
    local voiceGroup = soundsFolder and soundsFolder:FindFirstChild("OfficePuzzleVoice")
    if not (phonesFolder and voiceGroup) then
        warn("[Office:server] Phones/Sounds.OfficePuzzleVoice nao encontrados; puzzle desativado")
        return
    end

    -- Senha desta rodada (revelada via audio ao atender o telefone correto).
    local password = generatePassword()
    print(string.format("[Office:server] senha do puzzle: %s", password))

    -- Estado do puzzle (uma vez por load).
    local puzzleStarted = false
    local solved = false                       -- telefone verdadeiro ja atendido na rodada atual
    local starterPlayer: Player? = nil         -- quem iniciou o puzzle (recebe o erro de timeout)
    local timerToken = 0                       -- invalida o timer de atendimento anterior
    local failureRingToken = 0                 -- invalida o toque de falha anterior
    -- Telefones selecionados na rodada atual: [phone] = isReal (nil = nao selecionado).
    local selectedReal: { [Instance]: boolean } = {}

    -- Coleta os telefones (modelos com Base.ProximityPrompt).
    local phones = {}
    for _, child in ipairs(phonesFolder:GetChildren()) do
        local base = child:FindFirstChild("Base")
        if base and base:FindFirstChild("ProximityPrompt") then
            table.insert(phones, child)
        end
    end

    -- Silencia/desativa um telefone: para o RingPlayer, esconde o Billboard e desliga o Prompt.
    local function silencePhone(phone: Instance)
        local base = phone:FindFirstChild("Base")
        if not base then
            return
        end
        local ringPlayer = base:FindFirstChild("RingPlayer")
        local billboard = base:FindFirstChild("BillboardGui")
        local prompt = base:FindFirstChild("ProximityPrompt")
        if ringPlayer and ringPlayer:IsA("AudioPlayer") then
            ringPlayer:Stop()
        end
        if billboard then
            billboard.Enabled = false
        end
        if prompt then
            prompt.Enabled = false
        end
    end

    -- Desativa todos os telefones (baseline e limpeza ao reiniciar/parar/timeout).
    local function silenceAllPhones()
        for _, phone in ipairs(phones) do
            silencePhone(phone)
        end
    end

    -- Baseline: garante todos os telefones desligados no inicio.
    silenceAllPhones()

    -- Atendimento de um telefone por um player (acionou o ProximityPrompt). So age se o telefone
    -- estiver selecionado na rodada atual (selectedReal).
    local function onPhoneAnswered(player: Player, phone: Instance)
        local isReal = selectedReal[phone]
        if solved or isReal == nil then
            return
        end

        -- Para o Ring/Billboard/Prompt deste telefone e toca o Pick SO para quem atendeu (local).
        silencePhone(phone)
        local base = phone:FindFirstChild("Base")
        local pick = base and base:FindFirstChild("Pick")
        if pick then
            PlayPickSoundRemote:FireClient(player, pick)
        end

        if isReal then
            -- Verdadeiro: encerra a rodada, desliga todos os telefones (inclui o falso, se houver)
            -- e fala a senha SO para quem atendeu (no cliente dele).
            solved = true
            timerToken += 1
            silenceAllPhones()
            PlayPasswordVoiceRemote:FireClient(player, password)
        end
        -- Falso: apenas este telefone silencia; o verdadeiro continua tocando.
    end

    -- (Re)sorteia 1 ou 2 telefones, liga-os (Prompt/Billboard/Ring) e (re)inicia o timer de
    -- atendimento. Pode ser chamada varias vezes (loop): sempre limpa a rodada anterior antes.
    local function selectAndRing()
        silenceAllPhones()
        solved = false
        selectedReal = {}
        if #phones == 0 then
            return
        end

        local pool = table.clone(phones)
        shuffle(pool)
        local count = math.min(math.random(1, 2), #pool)

        for index = 1, count do
            local phone = pool[index]
            local isReal = index == 1 -- o primeiro sorteado e o verdadeiro
            selectedReal[phone] = isReal

            local base = phone:FindFirstChild("Base")
            if base then
                local billboard = base:FindFirstChild("BillboardGui")
                local ringPlayer = base:FindFirstChild("RingPlayer")
                local prompt = base:FindFirstChild("ProximityPrompt")
                if billboard then
                    billboard.Enabled = true
                end
                if ringPlayer and ringPlayer:IsA("AudioPlayer") then
                    ringPlayer.Looping = true -- mantem tocando ate ser atendido/silenciado
                    ringPlayer:Play()
                end
                if prompt then
                    prompt.Enabled = true
                end
            end
        end

        -- Timer de atendimento: se ninguem atender o verdadeiro a tempo, para os telefones e
        -- avisa +1 erro do puzzle para quem iniciou (o cliente decide reiniciar o loop ou falhar).
        timerToken += 1
        local myToken = timerToken
        task.delay(ANSWER_TIME, function()
            if myToken ~= timerToken or solved then
                return
            end
            silenceAllPhones()
            if starterPlayer and starterPlayer.Parent then
                AddPuzzleErrorRemote:FireClient(starterPlayer)
            end
        end)
    end

    -- Falha: varios telefones aleatorios tocam (so o som de Ring, sem Prompt/Billboard) por
    -- FAILURE_RING_TIME segundos, e entao param.
    local function playFailureRing()
        failureRingToken += 1
        local myToken = failureRingToken

        timerToken += 1 -- invalida qualquer timer de atendimento pendente
        silenceAllPhones()

        local pool = table.clone(phones)
        shuffle(pool)
        local count = math.min(FAILURE_RING_COUNT, #pool)

        local rung = {}
        for i = 1, count do
            local base = pool[i]:FindFirstChild("Base")
            local ringPlayer = base and base:FindFirstChild("RingPlayer")
            if ringPlayer and ringPlayer:IsA("AudioPlayer") then
                task.wait(math.random(0, 1))
                ringPlayer.Looping = true
                ringPlayer:Play()
                table.insert(rung, ringPlayer)
            end
        end

        task.delay(FAILURE_RING_TIME, function()
            if myToken ~= failureRingToken then
                return
            end
            for _, ringPlayer in ipairs(rung) do
                if ringPlayer.Parent then
                    ringPlayer:Stop()
                end
            end
        end)
    end

    -- Conecta o ProximityPrompt de TODOS os telefones uma unica vez. O onPhoneAnswered so age
    -- nos telefones selecionados da rodada atual (os demais ficam com o Prompt desabilitado).
    for index, phone in ipairs(phones) do
        local base = phone:FindFirstChild("Base")
        local prompt = base and base:FindFirstChild("ProximityPrompt")
        if prompt then
            ctx.Connections:Connect(ctx.Map, "OfficePhonePrompt" .. index, prompt.Triggered, function(plr: Player)
                onPhoneAnswered(plr, phone)
            end)
        end
    end

    -- Cliente sinaliza o fim da animacao do monitor: devolve a senha para o cliente e, na primeira
    -- vez, inicia o puzzle (sorteia os telefones).
    ctx.Connections:Connect(ctx.Map, "OfficeStartPhonePuzzle", StartPhonePuzzleRemote.OnServerEvent, function(player: Player)
        SetPasswordRemote:FireClient(player, password)
        if not puzzleStarted then
            puzzleStarted = true
            starterPlayer = player
            selectAndRing()
        end
    end)

    -- Erro (sem falhar ainda): recomeça o loop com novos telefones.
    ctx.Connections:Connect(ctx.Map, "OfficeRestartPhonePuzzle", RestartPhonePuzzleRemote.OnServerEvent, function(_player: Player)
        selectAndRing()
    end)

    -- Inicio da falha: para todos os telefones (a animacao de falha roda no cliente).
    ctx.Connections:Connect(ctx.Map, "OfficeStopPhones", StopPhonesRemote.OnServerEvent, function(_player: Player)
        timerToken += 1
        silenceAllPhones()
    end)

    -- Apos a animacao de falha: varios telefones aleatorios tocam (so o Ring) por ~30s.
    ctx.Connections:Connect(ctx.Map, "OfficeStartFailureRing", StartFailureRingRemote.OnServerEvent, function(_player: Player)
        playFailureRing()
    end)
end

-- Chamado pelo RoundService quando o COUNTDOWN da fuga acaba (ver RoundService.RunEscapePhase). O
-- Office fecha as DUAS portas do elevador simultaneamente (tween de CFrame ate o atributo
-- ClosedCFrame de cada porta) e, com elas fechadas, faz a transicao de tela (fade in/out) teleportando
-- os players de volta para a VotingRoom no meio (tela preta) — igual a transicao votacao->mapa.
-- BLOQUEIA ate o teleporte concluir (o RoundService descarrega o mapa logo depois). Os NPCs NAO sao
-- parados aqui: continuam ativos ate o OnUnload (ClearForMap).
function Office.OnEscapeEnd(ctx)
    print(string.format("[Office:server] OnEscapeEnd (loadId=%d) - fechando elevador e teleportando", ctx.LoadId))

    closeElevatorDoors(ctx.Map)

    local RoundService = ctx.GetService("RoundService")
    RoundService:PlayEscapeTransition(function()
        RoundService:TeleportPlayersToVotingRoom()
    end)
end

function Office.OnUnload(ctx)
    print(string.format("[Office:server] OnUnload (loadId=%d)", ctx.LoadId))
    -- Encerra os NPCs deste mapa (cancela movimento/animacoes) antes do RoundService destruir o mapa.
    ctx.GetService("NPCService"):ClearForMap(ctx.Map)
    -- ConnectionPlus ja desconecta o que foi registrado em ctx.Map; o mapa (e seus sons/telefones)
    -- e destruido pelo RoundService, encerrando qualquer Ring que ainda estivesse tocando.
end

return Office
