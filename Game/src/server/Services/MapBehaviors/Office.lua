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
local Players = game:GetService("Players")

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

-- BusinessMan: chance (0..1) de ele aparecer na rodada e a janela (s, contada do OnLoad) em que o
-- spawn acontece. Ele nao esta no mapa desde o inicio: fica dormente e surge no meio da rodada,
-- sempre num AINode fora do campo de visao dos players (ver NPCService:SpawnHidden).
local BUSINESSMAN_SPAWN_CHANCE = 0.99
local BUSINESSMAN_SPAWN_MIN_TIME = 60
local BUSINESSMAN_SPAWN_MAX_TIME = 90


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
-- Cliente sinaliza a primeira ativacao do tablet; o server reencaminha (uma vez) para todos os
-- clientes tocarem a animacao de startup no Frame ORIGINAL da SurfaceGui do tablet.
local PlayTabletStartupRemote: RemoteEvent
-- Cliente clica no ActionButton do tablet: inicia o boot dos servidores (todos -> 'Booting', e
-- cada um -> 'On' apos uma duracao aleatoria).
local StartServerBootRemote: RemoteEvent
-- Cliente clica em "Send Data" (sistema 'On'): inicia o envio de dados (barra de progresso de 1min,
-- com chance de servidores falharem no meio e precisarem de reboot fisico).
local StartSendDataRemote: RemoteEvent
-- Cliente sinaliza que digitou a senha correta no monitor (puzzle resolvido). O server contabiliza
-- no RoundService (estatisticas da rodada). A validacao da senha e feita no cliente (ele conhece a
-- senha via SetPassword), entao ele apenas avisa o server.
local SolvedPasswordRemote: RemoteEvent


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
    PlayTabletStartupRemote = ensure("PlayTabletStartup")
    StartServerBootRemote = ensure("StartServerBoot")
    StartSendDataRemote = ensure("StartSendData")
    SolvedPasswordRemote = ensure("SolvedPassword")
end

-- Duracao (s) aleatoria [min, max] para cada servidor sair de 'Booting' para 'On'.
local SERVER_BOOT_MIN = 15
local SERVER_BOOT_MAX = 20

-- Envio de dados ("Send Data"): duracao total (s) de progresso (so conta tempo RODANDO, pausas nao).
local SEND_TOTAL_TIME = 60
-- Chance (~por segundo de progresso) de um servidor falhar no meio do envio, e o progresso a partir
-- do qual nao ha mais falhas (para o envio sempre poder concluir).
local SEND_FAIL_CHANCE_PER_SEC = 0.04
local SEND_FAIL_MAX_PROGRESS = 0.9
-- Reboot de um servidor com falha: hold (s) do ProximityPrompt e duracao (s) do "rebooting".
local SERVER_REBOOT_HOLD = 1
local SERVER_REBOOT_TIME = 3


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

    -- Estatisticas da rodada: o Office contabiliza puzzles resolvidos no RoundService. Sao dois
    -- eventos que contam como puzzle resolvido: (1) o player digita a senha correta no monitor
    -- (avisado pelo cliente via SolvedPassword) e (2) o envio de dados do tablet conclui (creditado
    -- a quem iniciou o Send Data, mais abaixo na logica do envio).
    local RoundService = ctx.GetService("RoundService")

    -- Cada player so pode ser creditado uma vez pela senha por load (evita contagem duplicada).
    local passwordSolvedBy: { [Player]: boolean } = {}
    ctx.Connections:Connect(ctx.Map, "OfficeSolvedPassword", SolvedPasswordRemote.OnServerEvent, function(player: Player)
        if passwordSolvedBy[player] then
            return
        end
        passwordSolvedBy[player] = true
        if RoundService and RoundService.AddPuzzleSolved then
            RoundService:AddPuzzleSolved(player)
        end
    end)

    -- Secretary: NAO spawna na carga. Fica dormente (escondida) ate o puzzle do monitor falhar.
    -- Quando o cliente termina a animacao de falha, dispara SpawnSecretary e ela e spawnada como
    -- cacadora (estado Hunt) correndo atras de quem falhou. Ver NPCService / SharedModules.NPC.
    local NPCService = ctx.GetService("NPCService")
    NPCService:HideNPCInMap(ctx.Map, "Secretary")

    -- BusinessMan: tambem NAO spawna na carga. Fica dormente e, com BUSINESSMAN_SPAWN_CHANCE de
    -- chance, aparece num instante sorteado entre BUSINESSMAN_SPAWN_MIN_TIME e MAX_TIME segundos de
    -- rodada, num AINode que ninguem esteja vendo. Diferente da Secretary ele nao comeca cacando:
    -- entra no estado padrao do behavior (Idle -> Patrol) e caca por BARULHO, nao por visao — ver
    -- SharedModules.NPC.NPCBehaviors.BusinessMan.
    NPCService:HideNPCInMap(ctx.Map, "BusinessMan")

    if math.random() <= BUSINESSMAN_SPAWN_CHANCE then
        local delay = BUSINESSMAN_SPAWN_MIN_TIME
            + math.random() * (BUSINESSMAN_SPAWN_MAX_TIME - BUSINESSMAN_SPAWN_MIN_TIME)
        task.delay(delay, function()
            -- Mapa descarregado/trocado na espera (o RoundService o destroi): nao spawna.
            if not ctx.Map.Parent then
                return
            end
            NPCService:SpawnHidden(ctx.Map, "BusinessMan")
        end)
    end

    -- Ruido do mapa: qualquer AudioPlayer com o atributo "NoiseRadius" (telefones tocando,
    -- servidores ligando...) passa a atrair o NPC enquanto estiver tocando. O raio e autorado no
    -- Studio, entao nao ha codigo por puzzle aqui.
    ctx.GetService("NoiseService"):BindMapAudio(ctx.Map)

    local secretarySpawned = false
    ctx.Connections:Connect(ctx.Map, "OfficeSpawnSecretary", SpawnSecretaryRemote.OnServerEvent, function(player: Player)
        if secretarySpawned then
            return
        end
        secretarySpawned = true
        NPCService:SpawnHunter(ctx.Map, "Secretary", player)
    end)

    -- Tablet: a primeira ativacao dispara a animacao de startup no Frame ORIGINAL (world-space) da
    -- SurfaceGui do tablet para os DEMAIS players (o proprio ativador ja a toca localmente). O Cascade
    -- so roda no cliente (RunService.PreRender), por isso o server apenas reencaminha o gatilho, uma
    -- unica vez e excluindo o remetente (senao o ativador re-tocaria e a animacao dele reiniciaria no
    -- meio, no round-trip). Independente do puzzle dos telefones (fica acima do bloco que retorna cedo).
    local tabletStartupPlayed = false
    ctx.Connections:Connect(ctx.Map, "OfficePlayTabletStartup", PlayTabletStartupRemote.OnServerEvent, function(player: Player)
        if tabletStartupPlayed then
            return
        end
        tabletStartupPlayed = true
        for _, other in ipairs(Players:GetPlayers()) do
            if other ~= player then
                PlayTabletStartupRemote:FireClient(other)
            end
        end
    end)

    -- Estado dos servidores (backend autoritativo). Cada modelo em ctx.Map.Servers.ServerN carrega
    -- o atributo "State" ('Off' | 'Booting' | 'On'), que replica para os clientes (a UI do tablet
    -- reflete a cor de cada um e o Status agregado). Comecam em 'Off'.
    -- Tablet.Screen: onde ficam os atributos replicados do envio de dados (usados aqui pelo audio
    -- SendData de cada servidor e mais abaixo pela logica do "Send Data").
    local tabletScreen = resolve(ctx.Map, "Model", "Tablet", "Screen")

    -- Audio por servidor (AudioPlayers em model.Audios, cada um Wired a um AudioEmitter no modelo;
    -- tocam no server e replicam para todos). Reage as transicoes de estado:
    --   -> Booting: toca ServerStartBoot 1x; ao terminar, entra em loop no ServerRunningIdle.
    --   -> On:      nada (o ServerRunningIdle ja esta em loop desde o fim do boot).
    --   -> Off:     para tudo e toca ServerTurnOff 1x.
    -- O listener e conectado DEPOIS do 'Off' inicial, entao o load fica silencioso.
    local function setupServerAudio(model: Instance, index: number)
        local audios = model:FindFirstChild("Audios")
        if not audios then
            return
        end
        local boot = audios:FindFirstChild("ServerStartBoot") :: AudioPlayer?
        local idle = audios:FindFirstChild("ServerRunningIdle") :: AudioPlayer?
        local turnOff = audios:FindFirstChild("ServerTurnOff") :: AudioPlayer?
        local sendData = audios:FindFirstChild("SendData") :: AudioPlayer?

        -- Invalida callbacks de transicoes antigas (ex.: o Ended de um boot ja substituido).
        local token = 0

        -- SendData: toca em loop enquanto ESTE servidor esta 'On' E a barra esta PROGREDINDO (envio
        -- 'Active' e NAO pausado por falha). Qualquer outra combinacao para o som. Reavaliado a cada
        -- mudanca de State (do servidor), SendState ou SendFailed.
        local function refreshSendData()
            if not sendData then
                return
            end
            local progressing = tabletScreen ~= nil
                and tabletScreen:GetAttribute("SendState") == "Active"
                and tabletScreen:GetAttribute("SendFailed") ~= true
            if model:GetAttribute("State") == "On" and progressing then
                if not sendData.IsPlaying then
                    sendData.Looping = true
                    sendData:Play()
                end
            else
                sendData:Stop()
            end
        end

        local function stopAll()
            if boot then boot:Stop() end
            if idle then idle:Stop() end
            if turnOff then turnOff:Stop() end
            if sendData then sendData:Stop() end
        end

        ctx.Connections:Connect(ctx.Map, "OfficeServerAudio" .. index, model:GetAttributeChangedSignal("State"), function()
            token += 1
            local myToken = token
            local state = model:GetAttribute("State")

            if state == "Booting" then
                stopAll()
                if boot then
                    boot.Looping = false
                    boot.Ended:Once(function()
                        -- So entra no idle se ainda for ESTA transicao e o servidor nao caiu (Off).
                        local s = model:GetAttribute("State")
                        if myToken == token and idle and (s == "Booting" or s == "On") then
                            idle.Looping = true
                            idle:Play()
                        end
                    end)
                    boot:Play()
                elseif idle then
                    idle.Looping = true
                    idle:Play()
                end
            elseif state == "Off" then
                stopAll()
                if turnOff then
                    turnOff.Looping = false
                    turnOff:Play()
                end
            end
            -- "On": nada de boot/idle (o idle segue tocando); o SendData e reavaliado abaixo.
            refreshSendData()
        end)

        -- O SendData tambem liga/desliga quando o envio (SendState) ou a pausa por falha (SendFailed)
        -- mudam.
        if tabletScreen then
            ctx.Connections:Connect(ctx.Map, "OfficeServerSendAudio" .. index, tabletScreen:GetAttributeChangedSignal("SendState"), refreshSendData)
            ctx.Connections:Connect(ctx.Map, "OfficeServerSendFail" .. index, tabletScreen:GetAttributeChangedSignal("SendFailed"), refreshSendData)
        end
    end

    local serverModels = {}
    local serversFolder = ctx.Map:FindFirstChild("Servers")
    if serversFolder then
        for index, model in ipairs(serversFolder:GetChildren()) do
            if model:IsA("Model") then
                model:SetAttribute("State", "Off") -- estado inicial ANTES de conectar o audio (silencioso)
                table.insert(serverModels, model)
                setupServerAudio(model, index)
            end
        end
    end

    -- ActionButton clicado (uma vez por load): todos os servidores vao para 'Booting' e cada um
    -- decide uma duracao aleatoria de SERVER_BOOT_MIN..MAX segundos para ligar ('On').
    local serverBootStarted = false
    ctx.Connections:Connect(ctx.Map, "OfficeStartServerBoot", StartServerBootRemote.OnServerEvent, function(_player: Player)
        if serverBootStarted then
            return
        end
        serverBootStarted = true
        for _, model in ipairs(serverModels) do
            model:SetAttribute("State", "Booting")
            task.delay(math.random(SERVER_BOOT_MIN, SERVER_BOOT_MAX), function()
                if model.Parent then
                    model:SetAttribute("State", "On")
                end
            end)
        end
    end)

    -- Envio de dados ("Send Data"). Estado replicado via atributos no Tablet.Screen (a UI do tablet
    -- reflete): SendState ('Idle'|'Active'|'Done'), SendProgress (0..1), SendFailed (bool, barra
    -- vermelha enquanto pausado por falha de servidor). O progresso avanca em 1 minuto de tempo
    -- RODANDO; se um servidor falha no meio, ele para ate o player rebootar aquele servidor.
    -- (tabletScreen ja foi resolvido acima, junto ao setup de audio dos servidores.)
    if tabletScreen then
        tabletScreen:SetAttribute("SendState", "Idle")
        tabletScreen:SetAttribute("SendProgress", 0)
        tabletScreen:SetAttribute("SendFailed", false)
    end

    -- Cria um ProximityPrompt "Reboot" numa Part qualquer do servidor com falha; ao acionar, roda
    -- `onReboot` (que reinicia o servidor e retoma o envio). Sem Part, reinicia direto.
    local function spawnRebootPrompt(model: Instance, onReboot: () -> ())
        local part = model:FindFirstChildWhichIsA("BasePart", true)
        if not part then
            onReboot()
            return
        end
        local prompt = Instance.new("ProximityPrompt")
        prompt.Name = "RebootPrompt"
        prompt.ActionText = "Reboot"
        prompt.ObjectText = model.Name
        prompt.HoldDuration = SERVER_REBOOT_HOLD
        prompt.MaxActivationDistance = 10
        prompt.RequiresLineOfSight = false
        prompt.Parent = part

        local conn
        conn = prompt.Triggered:Connect(function()
            conn:Disconnect()
            prompt:Destroy()
            onReboot()
        end)
    end

    local sending = false
    -- Player que iniciou o envio de dados (creditado com o puzzle quando o envio concluir).
    local dataSender: Player? = nil
    ctx.Connections:Connect(ctx.Map, "OfficeStartSendData", StartSendDataRemote.OnServerEvent, function(player: Player)
        if sending or not tabletScreen then
            return
        end
        dataSender = player
        -- So envia com TODOS os servidores 'On'.
        for _, model in ipairs(serverModels) do
            if model:GetAttribute("State") ~= "On" then
                return
            end
        end
        sending = true
        tabletScreen:SetAttribute("SendFailed", false)
        tabletScreen:SetAttribute("SendProgress", 0)
        tabletScreen:SetAttribute("SendState", "Active")

        task.spawn(function()
            local elapsed = 0             -- tempo RODANDO acumulado (pausas por falha nao contam)
            local pushAccum = 0           -- acumulador p/ empurrar SendProgress ~10Hz
            local failCheckAccum = 0      -- acumulador p/ checar falha ~1x/s
            local failedServer: Instance? = nil  -- servidor em falha atual (pausa o progresso)

            while elapsed < SEND_TOTAL_TIME and ctx.Map.Parent do
                local dt = task.wait()
                -- Enquanto houver um servidor em falha, o progresso fica pausado (nao acumula tempo).
                if failedServer == nil then
                    elapsed += dt
                    local progress = math.min(elapsed / SEND_TOTAL_TIME, 1)

                    pushAccum += dt
                    if pushAccum >= 0.1 or progress >= 1 then
                        pushAccum = 0
                        tabletScreen:SetAttribute("SendProgress", progress)
                    end

                    -- Chance (~1x/s) de um servidor 'On' falhar no meio do envio.
                    failCheckAccum += dt
                    if failCheckAccum >= 1 then
                        failCheckAccum -= 1
                        if progress < SEND_FAIL_MAX_PROGRESS and math.random() < SEND_FAIL_CHANCE_PER_SEC then
                            local candidates = {}
                            for _, model in ipairs(serverModels) do
                                if model:GetAttribute("State") == "On" then
                                    table.insert(candidates, model)
                                end
                            end
                            if #candidates > 0 then
                                local model = candidates[math.random(#candidates)]
                                failedServer = model
                                -- Falha = servidor cai para 'Off': o agregado do sistema vira 'Off'
                                -- (Status vermelho) e o envio fica pausado ate o reboot.
                                model:SetAttribute("State", "Off")
                                tabletScreen:SetAttribute("SendFailed", true)
                                spawnRebootPrompt(model, function()
                                    -- Player promptou o reboot: "rebooting" (Booting) e, ao concluir,
                                    -- volta 'On' e retoma o progresso.
                                    model:SetAttribute("State", "Booting")
                                    task.delay(SERVER_REBOOT_TIME, function()
                                        if not ctx.Map.Parent then
                                            return
                                        end
                                        model:SetAttribute("State", "On")
                                        tabletScreen:SetAttribute("SendFailed", false)
                                        failedServer = nil
                                    end)
                                end)
                            end
                        end
                    end
                end
            end

            if ctx.Map.Parent then
                tabletScreen:SetAttribute("SendProgress", 1)
                tabletScreen:SetAttribute("SendFailed", false)
                tabletScreen:SetAttribute("SendState", "Done")
                -- Envio concluido: conta como um puzzle resolvido para quem iniciou o Send Data.
                if dataSender and RoundService and RoundService.AddPuzzleSolved then
                    RoundService:AddPuzzleSolved(dataSender)
                end
            end
            -- `sending` permanece true: o envio e um evento unico por load.
        end)
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
    -- Solta os AudioPlayers deste mapa do NoiseService (senao ficariam na tabela apos o Destroy).
    ctx.GetService("NoiseService"):UnbindMap(ctx.Map)
    -- ConnectionPlus ja desconecta o que foi registrado em ctx.Map; o mapa (e seus sons/telefones)
    -- e destruido pelo RoundService, encerrando qualquer Ring que ainda estivesse tocando.
end

return Office
