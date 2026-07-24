-- MapBehaviors/Office (client)
-- Comportamento client do mapa Office. E carregado pelo MapController quando o mapa
-- e resolvido localmente, ANTES de confirmar prontidao ao servidor (MapReady).
--
-- ctx:
--   ctx.Map           : Model    -> o mapa em Workspace.MapInUse.ActiveMap
--   ctx.MapName       : string
--   ctx.LoadId        : number
--   ctx.GetController : (string) -> Controller  -> acessa qualquer Controller da place
--   ctx.Connections   : ConnectionPlus           -> maid; desconecta tudo no Unload/Destroying

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")

local spr = require(ReplicatedStorage.Shared.SharedModules.SpringEffects)
local UIAnimator = require(ReplicatedStorage.ExternalPackages.twinkle)

local Office = {}

-- Numero total de tentativas de senha antes da falha. A cada erro o TextBox/Warning ficam
-- 1/total mais transparentes e o Container escurece 1/total em direcao ao preto; ao atingir o
-- total (transparencia 1 / container preto) dispara a sequencia de falha ("YOU FAILED" -> "RUN").
local MAX_PASSWORD_ERRORS = 3

-- Intervalo (s) entre cada digito da senha falada ao atender o telefone correto.
local DIGIT_INTERVAL = 1

-- Faixa (s) do intervalo aleatorio entre trovoes do ambiente de chuva (InitialSounds.Rain).
local THUNDER_MIN_INTERVAL = 8
local THUNDER_MAX_INTERVAL = 25

-- Tempo (s) que esperamos os objetos do ManagerPC replicarem antes de desistir do bind do puzzle
-- do monitor (o OnLoad roda ANTES do mapa terminar de carregar para o cliente).
local MANAGER_PC_WAIT = 30

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

-- Como resolve(), mas ESPERA cada no aparecer (WaitForChild com timeout). Usado quando o OnLoad roda
-- antes do mapa terminar de replicar: em vez de faltar instancia e abortar o bind, aguardamos o
-- objeto carregar. YIELDA, entao so pode ser chamado fora do fluxo do OnLoad (ex.: em task.spawn).
-- Retorna nil se algum no nao aparecer dentro do timeout.
local function waitResolve(root: Instance?, timeout: number, ...: string): Instance?
    local current = root
    for _, name in { ... } do
        if not current then
            return nil
        end
        current = current:WaitForChild(name, timeout)
    end
    return current
end

function Office.OnLoad(ctx)
    --print(string.format("[Office:client] OnLoad (loadId=%d)", ctx.LoadId))

    -- Ambiente de chuva: a cada intervalo aleatorio, toca um trovao (AudioPlayer "Thunder") de uma
    -- Part aleatoria de ctx.Map.InitialSounds.Rain. Os Thunder tem Ignore=true, entao nao tocam no
    -- fade-out inicial (VoteController:PlayInitialSounds) como os demais InitialSounds. O loop para
    -- sozinho quando o mapa e descarregado (ctx.Map.Parent vira nil).
    local rainFolder = resolve(ctx.Map, "InitialSounds", "Rain")
    if rainFolder then
        local thunders: { AudioPlayer } = {}
        for _, part in rainFolder:GetChildren() do
            local thunder = part:FindFirstChild("Thunder")
            if thunder and thunder:IsA("AudioPlayer") then
                table.insert(thunders, thunder)
            end
        end

        if #thunders > 0 then
            task.spawn(function()
                while ctx.Map.Parent do
                    task.wait(math.random(THUNDER_MIN_INTERVAL, THUNDER_MAX_INTERVAL))
                    if not ctx.Map.Parent then
                        break
                    end
                    thunders[math.random(#thunders)]:Play()
                end
            end)
        end
    end

    -- Dispara um remote client->server do puzzle do Office pelo nome (resolve sob demanda; o
    -- server cria os remotes apos a barreira de prontidao).
    local function fireOfficeServer(remoteName: string)
        local comms = ReplicatedStorage:FindFirstChild("Comms")
        local office = comms and comms:FindFirstChild("Office")
        local remote = office and office:FindFirstChild(remoteName)
        if remote and remote:IsA("RemoteEvent") then
            remote:FireServer()
        end
    end

    -- Tablet ("Servers"): ao acionar o ProximityPrompt do Screen, traz o conteudo da SurfaceGui para
    -- o monitor fullscreen (MonitorsGUI) via MonitorScreenController e toca a animacao de startup do
    -- Cascade ("ServerTabletStartup") no clone. Na PRIMEIRA ativacao (gate no server), pede que TODOS
    -- os clientes toquem a mesma animacao no Frame ORIGINAL (world-space) da SurfaceGui, para o tablet
    -- do mundo tambem "ligar" para todos os players (o Cascade so roda no cliente - RunService.PreRender
    -- -, entao o server apenas reencaminha o gatilho uma unica vez).
    do
        local tabletScreen = resolve(ctx.Map, "Model", "Tablet", "Screen")
        local tabletPrompt = tabletScreen and tabletScreen:FindFirstChild("ProximityPrompt") :: ProximityPrompt?
        local tabletContent = resolve(tabletScreen, "SurfaceGui", "TabletMonitorContent") :: Frame?

        if tabletPrompt and tabletContent then
            local monitorScreen = ctx.GetController("MonitorScreenController")
            -- Guarda contra reentrada: enquanto o tablet estiver aberto, novos Triggered sao ignorados
            -- (so reabre depois que o BackButton fecha).
            local tabletOpen = false

            -- Toca "Server_Show" em lote (Stagger 0.2) em cada Server do RoomVisualizer de `root`,
            -- fazendo-os aparecer um apos o outro. `root` pode ser o clone (MonitorsGUI) ou o Frame
            -- ORIGINAL (world-space) da SurfaceGui.
            local function playServerShow(root: Instance)
                local serversContainer = resolve(root, "RoomVisualizer", "Servers")
                if not serversContainer then
                    return
                end
                local serverFrames = {}
                for _, child in serversContainer:GetChildren() do
                    if child:IsA("GuiObject") then
                        table.insert(serverFrames, child)
                    end
                end
                if #serverFrames > 0 then
                    monitorScreen:PlayAnimationBatch(serverFrames, "Server_Show", { Stagger = 0.2 })
                end
            end

            -- ===== Estado dos servidores (backend autoritativo, refletido na UI) =====
            -- Cada modelo em ctx.Map.Servers.ServerN carrega o atributo replicado "State"
            -- ('Off' | 'Booting' | 'On'), setado pelo server. A UI (clone no MonitorsGUI e o Frame
            -- world-space) reflete a cor de cada servidor e um Status agregado do sistema.
            local STATE_COLORS = {
                Off = Color3.fromRGB(255, 0, 0),        -- vermelho (inclui servidor que falhou no envio)
                Booting = Color3.fromRGB(255, 255, 0),  -- amarelo
                On = Color3.fromRGB(0, 255, 0),         -- verde
            }
            local DEFAULT_STATE = "Off"

            -- Cor da barra de progresso quando o envio esta pausado por falha de servidor.
            local BAR_FAIL_COLOR = Color3.fromRGB(255, 0, 0)
            -- Cor de repouso da barra, capturada do template para respeitar o design original.
            local barBaseColor = Color3.fromRGB(122, 122, 122)
            do
                local baseBar = resolve(tabletContent, "ButtonContainer", "ProgressBar", "Bar")
                if baseBar and baseBar:IsA("GuiObject") then
                    barBaseColor = baseBar.BackgroundColor3
                end
            end

            -- Modelos dos servidores, indexados pelo numero do nome (Server1 -> 1).
            local serverModels: { [number]: Instance } = {}
            local serversFolder = ctx.Map:FindFirstChild("Servers")
            if serversFolder then
                for _, model in serversFolder:GetChildren() do
                    local num = tonumber(string.match(model.Name, "%d+"))
                    if num then
                        serverModels[num] = model
                    end
                end
            end

            -- Estado individual de um servidor (atributo replicado do modelo; default 'Off').
            local function getServerState(num: number): string
                local model = serverModels[num]
                local state = model and model:GetAttribute("State")
                return if typeof(state) == "string" then state else DEFAULT_STATE
            end

            -- Estado agregado do sistema: o "pior" estado vence (Off > Booting > On). Se algum
            -- servidor esta Off, o sistema esta Off; senao, se algum esta Booting, Booting; senao On.
            local function getSystemState(): string
                local anyBooting = false
                local hasAny = false
                for num in serverModels do
                    hasAny = true
                    local s = getServerState(num)
                    if s == "Off" then
                        return "Off"
                    elseif s == "Booting" then
                        anyBooting = true
                    end
                end
                if not hasAny then
                    return DEFAULT_STATE
                end
                return if anyBooting then "Booting" else "On"
            end

            -- Colore cada Server da UI de `root` conforme o estado do seu respectivo modelo (casa o
            -- numero do ServerNumber com o do modelo).
            local function refreshServersUI(root: Instance)
                local serversContainer = resolve(root, "RoomVisualizer", "Servers")
                if not serversContainer then
                    return
                end
                for _, frame in serversContainer:GetChildren() do
                    if frame:IsA("GuiObject") then
                        local label = frame:FindFirstChild("ServerNumber")
                        local num = label and label:IsA("TextLabel") and tonumber(label.Text)
                        if num then
                            frame.BackgroundColor3 = STATE_COLORS[getServerState(num)] or STATE_COLORS.Off
                        end
                    end
                end
            end

            -- Atualiza a Status (texto + cor) e o ActionButton (texto + visibilidade) conforme o
            -- sistema. O botao some enquanto o sistema esta ligando (Booting) ou enquanto o envio de
            -- dados esta em andamento/concluido. Com o sistema 'On', o texto vira "Send Data".
            local function refreshStatusUI(root: Instance)
                local systemState = getSystemState()
                local color = STATE_COLORS[systemState] or STATE_COLORS.Off
                local status = resolve(root, "ButtonContainer", "Status")
                if status and status:IsA("TextLabel") then
                    status.Text = systemState
                    status.TextColor3 = color
                end
                local actionBtn = resolve(root, "ButtonContainer", "ActionButton")
                if actionBtn and actionBtn:IsA("TextButton") then
                    local sendState = tabletScreen:GetAttribute("SendState")
                    local sending = sendState == "Active" or sendState == "Done"
                    if systemState == "Booting" or sending then
                        actionBtn.Visible = false
                    else
                        actionBtn.Visible = true
                        actionBtn.Text = if systemState == "On" then "Send Data" else "Turn Systems On"
                    end
                end
            end

            -- Reflete o envio de dados na UI de `root`: mostra/esconde a ProgressBar, preenche a Bar
            -- (X.Scale = progresso 0..1) e pinta de vermelho quando pausado por falha de servidor.
            local function refreshSendUI(root: Instance)
                local progressBar = resolve(root, "ButtonContainer", "ProgressBar")
                if not (progressBar and progressBar:IsA("GuiObject")) then
                    return
                end
                local sendState = tabletScreen:GetAttribute("SendState")
                progressBar.Visible = sendState == "Active" or sendState == "Done"

                local bar = progressBar:FindFirstChild("Bar")
                if bar and bar:IsA("GuiObject") then
                    local progress = tabletScreen:GetAttribute("SendProgress")
                    progress = if typeof(progress) == "number" then math.clamp(progress, 0, 1) else 0
                    local y = bar.Size.Y
                    bar.Size = UDim2.new(progress, 0, y.Scale, y.Offset)
                    local failed = tabletScreen:GetAttribute("SendFailed") == true
                    bar.BackgroundColor3 = if failed then BAR_FAIL_COLOR else barBaseColor
                end
            end

            -- Atualiza toda a UI (servers + status + envio) de um root, se existir e estiver na arvore.
            local function refreshRoot(root: Instance?)
                if root and root.Parent then
                    refreshServersUI(root)
                    refreshStatusUI(root)
                    refreshSendUI(root)
                end
            end

            -- Atualiza o clone no MonitorsGUI (se aberto) e o Frame ORIGINAL (world-space).
            local function refreshAll()
                refreshRoot(monitorScreen:GetContent(tabletContent.Name))
                refreshRoot(tabletContent)
            end

            -- Liga/desliga o loop do LoadingStick (Cascade "LoadingStick_Anim") num root conforme o
            -- envio esteja ativo. Tocar durante o envio; parar caso contrario.
            local function applyLoadingStick(root: Instance?)
                if not (root and root.Parent) then
                    return
                end
                local ls = resolve(root, "ButtonContainer", "ProgressBar", "TextContainer", "LoadingStick")
                if not ls then
                    return
                end
                if tabletScreen:GetAttribute("SendState") == "Active" then
                    monitorScreen:PlayAnimation(ls, "LoadingStick_Anim")
                else
                    monitorScreen:StopAnimation(ls)
                end
            end
            local function updateLoadingStick()
                applyLoadingStick(monitorScreen:GetContent(tabletContent.Name))
                applyLoadingStick(tabletContent)
            end

            -- Reflete cada mudanca de estado (atributo replicado) na UI. Roda em todos os clientes,
            -- entao o Frame world-space acompanha o estado para quem estiver olhando o tablet do mundo.
            for num, model in serverModels do
                ctx.Connections:Connect(ctx.Map, "OfficeServerState" .. num, model:GetAttributeChangedSignal("State"), refreshAll)
            end

            -- Atributos replicados do envio de dados (setados pelo server em ctx.Map.Model.Tablet.Screen).
            ctx.Connections:Connect(ctx.Map, "OfficeSendProgress", tabletScreen:GetAttributeChangedSignal("SendProgress"), refreshAll)
            ctx.Connections:Connect(ctx.Map, "OfficeSendFailed", tabletScreen:GetAttributeChangedSignal("SendFailed"), refreshAll)
            ctx.Connections:Connect(ctx.Map, "OfficeSendState", tabletScreen:GetAttributeChangedSignal("SendState"), function()
                refreshAll()
                updateLoadingStick()
            end)

            -- Estado inicial na UI (em thread propria: getMonitorsGui usa WaitForChild e nao pode
            -- bloquear o OnLoad/MapReady).
            task.spawn(refreshAll)

            ctx.Connections:Connect(ctx.Map, "OfficeTabletPrompt", tabletPrompt.Triggered, function()
                if tabletOpen then
                    return
                end
                tabletOpen = true

                -- Traz o conteudo do tablet para o monitor fullscreen. Se o clone ja estava la (mesmo
                -- nome), so reabre (fresh=false, sem re-animar); senao clona e toca o startup.
                local clone, startupSignal, fresh = monitorScreen:ShowFrame(tabletContent, "ServerTabletStartup")
                if fresh then
                    -- Espelha o startup no Frame ORIGINAL (world-space) da SurfaceGui para o proprio
                    -- ativador (writes de Cascade num instance server sao locais, entao so ele ve): o
                    -- clone e o tablet do mundo animam em paralelo.
                    monitorScreen:PlayAnimation(tabletContent, "ServerTabletStartup")
                    -- E pede ao server para reencaminhar o startup aos DEMAIS players (uma unica vez).
                    fireOfficeServer("PlayTabletStartup")
                end

                -- Com o Frame ja todo na PlayerGui, libera os botoes ActionButton e BackButton.
                local actionButton = resolve(clone, "ButtonContainer", "ActionButton") :: TextButton?
                local backButton = clone:FindFirstChild("BackButton") :: TextButton?
                if actionButton then
                    actionButton.Interactable = true
                    actionButton.Active = true
                    -- Clicar depende do estado do sistema: com 'Off' inicia o boot dos servidores;
                    -- com 'On' (botao "Send Data") inicia o envio de dados. O backend decide tudo.
                    ctx.Connections:Connect(ctx.Map, "OfficeTabletAction", actionButton.Activated, function()
                        local systemState = getSystemState()
                        if systemState == "On" then
                            fireOfficeServer("StartSendData")
                        elseif systemState == "Off" then
                            fireOfficeServer("StartServerBoot")
                        end
                    end)
                end
                if backButton then
                    backButton.Interactable = true
                    backButton.Active = true
                end

                -- Reflete o estado atual (servidores + envio) na UI recem-exibida e liga o LoadingStick
                -- caso um envio ja esteja em andamento.
                refreshAll()
                updateLoadingStick()

                -- Ancora o personagem e libera o mouse (visivel, para clicar nos botoes) enquanto o
                -- tablet estiver aberto.
                local character = Players.LocalPlayer.Character
                local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
                if hrp then
                    hrp.Anchored = true
                end
                local viewmodel = ctx.GetController("ViewmodelController"):GetViewmodel()
                if viewmodel then
                    viewmodel:SetFreeMouse(true)
                end

                -- BackButton: fecha o tablet -> desancora o personagem, retrava o mouse e apenas
                -- ESCONDE o MonitorsGUI (Hide nao apaga o clone; ele fica para ser reaproveitado na
                -- proxima abertura). A decisao de apagar/re-clonar fica no Triggered, via :ShowFrame.
                if backButton then
                    ctx.Connections:Connect(ctx.Map, "OfficeTabletBack", backButton.Activated, function()
                        if not tabletOpen then
                            return
                        end
                        tabletOpen = false
                        if hrp then
                            hrp.Anchored = false
                        end
                        if viewmodel then
                            viewmodel:SetFreeMouse(false)
                        end
                        monitorScreen:Hide()
                    end)
                end

                -- Quando o startup TERMINAR, toca "Server_Show" em lote tanto no clone (MonitorsGUI)
                -- quanto no Frame ORIGINAL (world-space) da SurfaceGui, para os Servers aparecerem um
                -- a um nos dois para o ativador.
                if startupSignal then
                    startupSignal:Connect(function(event)
                        if event ~= "Completed" then
                            return
                        end
                        playServerShow(clone)
                        playServerShow(tabletContent)
                    end)
                end
            end)

            -- Reencaminhado pelo server na primeira ativacao: toca a animacao de startup no Frame
            -- ORIGINAL (world-space) da SurfaceGui do tablet. O remote so existe apos a barreira de
            -- prontidao, entao a conexao e feita de forma assincrona (nao trava o MapReady).
            task.spawn(function()
                local comms = ReplicatedStorage:WaitForChild("Comms", 30)
                local office = comms and comms:WaitForChild("Office", 30)
                local playTabletStartup = office and office:WaitForChild("PlayTabletStartup", 30)
                if not playTabletStartup or not ctx.Map.Parent then
                    return
                end
                ctx.Connections:Connect(ctx.Map, "OfficeWorldTabletStartup", playTabletStartup.OnClientEvent, function()
                    monitorScreen:PlayAnimation(tabletContent, "ServerTabletStartup")
                end)
            end)
        end
    end

    -- ManagerPC (puzzle do monitor): o OnLoad roda ANTES do mapa terminar de replicar para o cliente,
    -- entao os objetos do ManagerPC podem ainda nao existir. Em vez de abortar, esperamos (WaitForChild)
    -- o ManagerPC e seus filhos aparecerem - ou seja, o mapa ja carregado com o player dentro - numa
    -- thread propria (nao pode bloquear o OnLoad/MapReady) e so entao fazemos o bind.
    task.spawn(function()
        local managerPC = waitResolve(ctx.Map, MANAGER_PC_WAIT, "Model", "ManagerPC")
        local prompt = waitResolve(managerPC, MANAGER_PC_WAIT, "Keyboard", "Union", "ProximityPrompt") :: ProximityPrompt?
        local cameraPart = waitResolve(managerPC, MANAGER_PC_WAIT, "Cameras", "1") :: BasePart?
        local surfaceGui = waitResolve(managerPC, MANAGER_PC_WAIT, "SmallMonitor", "Part", "SurfaceGui") :: SurfaceGui?
        local container = surfaceGui and surfaceGui:WaitForChild("Container", MANAGER_PC_WAIT) :: Frame?
        local textBox = container and container:WaitForChild("TextBox", MANAGER_PC_WAIT) :: TextBox?
        local warning = container and container:WaitForChild("Warning", MANAGER_PC_WAIT) :: TextLabel?
        local runText = container and container:WaitForChild("RunText", MANAGER_PC_WAIT) :: TextLabel?
        -- SpotLight do monitor (opcional): desligado quando o jogador falha.
        local spotLight = resolve(managerPC, "SmallMonitor", "Part", "SpotLight") :: SpotLight?

        -- Mapa descarregado enquanto esperavamos: nao faz sentido bindar.
        if not ctx.Map.Parent then
            return
        end
        if not (prompt and cameraPart and surfaceGui and container and textBox and warning and runText) then
            warn("[Office:client] Instancias do ManagerPC faltando mesmo apos esperar; bind cancelado")
            return
        end

        -- Senha do monitor: gerada e enviada pelo server (SetPassword) quando o puzzle inicia.
        -- Fica nil ate chegar; sem ela nao validamos o que e digitado.
        local password: string? = nil

        -- Guarda os valores de repouso para a tremida sempre voltar ao estado original.
        local textBoxBasePos = textBox.Position
        local textBoxBaseColor = textBox.TextColor3
        local warningBasePos = warning.Position
        local warningBaseRot = warning.Rotation
        local warningBaseColor = warning.TextColor3

        -- Tremida ao errar a senha: o TextBox treme so na posicao; o Warning (TextLabel) treme na
        -- posicao e rotacao, e ainda pisca vermelho voltando para a cor original. As nudges iniciais
        -- sao corrigidas por springs subamortecidos (damping baixo), gerando o balanco da tremida.
        local function shakeOnWrongPassword()
            -- TextBox: apenas posicao.
            textBox.Position = textBoxBasePos + UDim2.fromScale(0.05, 0)
            textBox.TextColor3 = Color3.fromRGB(255, 0, 0)
            spr.target(textBox, 0.25, 7, { Position = textBoxBasePos })
            spr.target(textBox, 1, 2.5, { TextColor3 = textBoxBaseColor })

            -- Warning: posicao + rotacao, e flash vermelho de volta a cor original.
            warning.Position = warningBasePos + UDim2.fromScale(0.04, 0)
            warning.Rotation = warningBaseRot + 10
            warning.TextColor3 = Color3.fromRGB(255, 0, 0)
            spr.target(warning, 0.25, 7, {
                Position = warningBasePos,
                Rotation = warningBaseRot,
            })
            spr.target(warning, 1, 2.5, { TextColor3 = warningBaseColor })
        end

        -- Cor de repouso do Container, usada para escurece-lo ate o preto conforme os erros.
        local containerBaseColor = container.BackgroundColor3

        -- Estado do monitor, compartilhado entre o prompt, o botao Back e a checagem de senha.
        local activated = false      -- monitor aberto (camera presa nele)
        local introPlayed = false    -- animacoes de entrada ja tocaram (so na primeira visita)
        local errorCount = 0         -- quantidade de senhas erradas acumuladas
        local failed = false         -- jogador esgotou as tentativas
        local unlocked = false       -- jogador acertou a senha

        -- Bloqueio de digitacao enquanto qualquer animacao/efeito do monitor estiver rodando. E um
        -- contador (beginBusy/endBusy se aninham): o TextBox so volta a aceitar texto quando o contador
        -- zera e o puzzle nao foi resolvido/falhado. Comeca desabilitado ate a intro liberar.
        local busyCount = 0
        local function setTextBoxEnabled(enabled: boolean)
            textBox.TextEditable = enabled
            textBox.Selectable = enabled
            if not enabled then
                textBox:ReleaseFocus()
            end
        end
        local function beginBusy()
            busyCount += 1
            if busyCount == 1 then
                setTextBoxEnabled(false)
            end
        end
        local function endBusy()
            busyCount = math.max(0, busyCount - 1)
            if busyCount == 0 and not failed and not unlocked then
                setTextBoxEnabled(true)
            end
        end
        setTextBoxEnabled(false)

        -- Botao "Back" da GeneralUis: aparece ao abrir o monitor e, ao ser clicado, devolve o
        -- jogador ao estado anterior (camera/mouse/viewmodel). Comeca escondido.
        local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
        local backButton = resolve(playerGui, "SharedGuis", "GeneralUis", "Frame", "Back") :: ImageButton?
        if backButton then
            backButton.Visible = false
        end

        -- Remove os labels de caractere gerados pelo efeito de texto do twinkle no Container.
        local function clearCharLabels()
            for _, child in container:GetChildren() do
                if child:GetAttribute("CharLabel") then
                    child:Destroy()
                end
            end
        end

        -- Anima um texto no Warning com o efeito "Glitch" (mesmo padrao da intro): esconde o label,
        -- toca o efeito e, ao terminar, limpa os char labels e restaura o Warning ja com o texto final.
        local function showWarningGlitch(text: string, onComplete: (() -> ())?)
            UIAnimator.ShowText(container, warning, text, {
                effect = "Glitch",
                onComplete = function()
                    clearCharLabels()
                    warning.Text = text
                    warning.Visible = true
                    if onComplete then
                        onComplete()
                    end
                end,
            })
        end

        -- Sai do monitor e restaura o estado anterior ao acionamento do prompt: devolve a camera ao
        -- jogador (Custom), retrava o mouse em primeira pessoa e retoma o viewmodel. O :Resume
        -- reexibe automaticamente o modelo do item SE havia algum equipado quando o monitor abriu
        -- (o viewmodel foi apenas pausado/escondido, nao destruido).
        local function exitMonitor()
            if not activated then
                return
            end
            activated = false

            if backButton then
                backButton.Visible = false
            end

            -- Devolve a camera ao jogador (Custom) ANTES de retomar o viewmodel.
            local camera = workspace.CurrentCamera
            camera.CameraType = Enum.CameraType.Custom

            -- Retrava o mouse em primeira pessoa (cursor escondido, travado no centro).
            UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
            UserInputService.MouseIconEnabled = false

            local viewmodel = ctx.GetController("ViewmodelController"):GetViewmodel()
            if viewmodel then
                viewmodel:Resume()
            end
        end

        if backButton then
            ctx.Connections:Connect(ctx.Map, "OfficeBackButton", backButton.Activated, exitMonitor)
        end

        -- Sequencia de falha (tentativas esgotadas): toca "YOU FAILED" e depois "RUN" com efeito
        -- Glitch no RunText, apaga o texto, desliga o monitor (SurfaceGui + SpotLight) e restaura a
        -- camera/mouse/viewmodel (igual ao botao Back). Roda em sua propria thread (yielda).
        local function playFailure()
            UIAnimator.ShowText(container, runText, "YOU FAILED", {
                effect = "Glitch",
                onComplete = function()
                    clearCharLabels()
                    runText.Text = "YOU FAILED"
                    runText.Visible = true

                    task.wait(2)

                    UIAnimator.ShowText(container, runText, "RUN", {
                        effect = "Glitch",
                        onComplete = function()
                            clearCharLabels()
                            runText.Text = "RUN"
                            runText.Visible = true

                            task.wait(1)

                            -- Apaga o texto e desliga o monitor.
                            runText.Text = ""
                            runText.Visible = false
                            surfaceGui.Enabled = false
                            if spotLight then
                                spotLight.Enabled = false
                            end

                            -- Restaura camera/mouse/viewmodel (igual ao botao Back).
                            exitMonitor()

                            -- Depois da animacao de falha: pede ao server para tocar varios telefones
                            -- aleatorios (so o som de Ring) por ~30s.
                            fireOfficeServer("StartFailureRing")

                            -- E spawna a Secretary cacadora, que passa a correr atras do player.
                            fireOfficeServer("SpawnSecretary")
                        end,
                    })
                end,
            })
        end

        -- Avanca o progresso de erro do puzzle (n/total): deixa o TextBox/Warning mais transparentes
        -- e o Container mais preto; ao esgotar as tentativas (transparencia 1 / container preto)
        -- dispara a sequencia de falha. Usado tanto pela senha errada quanto pelo timeout do telefone.
        -- Se ainda houver tentativas: roda `onRetry` (se passado) para o feedback do erro, ou apenas
        -- recomeça o loop dos telefones (timeout).
        local function addPuzzleError(onRetry: (() -> ())?)
            if failed then
                return
            end

            errorCount += 1
            local ratio = math.clamp(errorCount / MAX_PASSWORD_ERRORS, 0, 1)
            spr.target(textBox, 1, 2.5, { TextTransparency = ratio, BackgroundTransparency = ratio })
            spr.target(warning, 1, 2.5, { TextTransparency = ratio })
            spr.target(container, 1, 2.5, {
                BackgroundColor3 = containerBaseColor:Lerp(Color3.new(0, 0, 0), ratio),
            })

            if errorCount >= MAX_PASSWORD_ERRORS then
                failed = true
                -- Falhou: para os telefones que estiverem tocando, espera e roda a animacao de falha
                -- (que ao final pede o toque de varios telefones).
                fireOfficeServer("StopPhones")
                task.wait(2)
                task.spawn(playFailure)
            elseif onRetry then
                -- Errou mas ainda tem tentativas: roda o feedback do erro (que ao final recomeça o loop).
                task.spawn(onRetry)
            else
                -- Errou mas ainda tem tentativas (timeout): recomeça o loop (o server sorteia novos telefones).
                fireOfficeServer("RestartPhonePuzzle")
            end
        end

        -- Feedback ao errar a senha mas ainda ter tentativas: para imediatamente o telefone que esta
        -- tocando, espera a tremida (animacao de erro) assentar e entao anima no Warning, com efeito
        -- Glitch, "Incorrect password", depois (1s) "You have N more attempts" (N = tentativas
        -- restantes) e por fim o texto original "Pick the next call"; ao terminar, recomeça o loop dos
        -- telefones no server. Yielda (roda em sua propria thread via task.spawn no addPuzzleError).
        local function playRetryFeedback()
            fireOfficeServer("StopPhones")

            local remaining = MAX_PASSWORD_ERRORS - errorCount
            local attemptsText = string.format(
                "You have %d more attempt%s",
                remaining,
                if remaining == 1 then "" else "s"
            )

            -- Espera a animacao de erro (tremida) assentar antes de reescrever o Warning.
            task.wait(1)
            showWarningGlitch("Incorrect password", function()
                task.wait(1)
                showWarningGlitch(attemptsText, function()
                    task.wait(1)
                    showWarningGlitch("Pick the next call", function()
                        fireOfficeServer("RestartPhonePuzzle")
                        -- Fim da sequencia de feedback: libera o TextBox para a proxima tentativa.
                        endBusy()
                    end)
                end)
            end)
        end

        -- Senha digitada errada: treme e contabiliza um erro do puzzle (com feedback de retentativa).
        -- Marca o monitor como ocupado durante toda a sequencia (tremida + glitches), bloqueando a
        -- digitacao; o endBusy correspondente roda no fim de playRetryFeedback.
        local function onWrongPassword()
            if failed then
                return
            end
            beginBusy()
            shakeOnWrongPassword()
            addPuzzleError(playRetryFeedback)
        end

        -- Senha digitada correta: deixa o texto do TextBox e do Warning verdes. Puzzle resolvido, entao
        -- o TextBox fica desabilitado de vez (nao ha mais o que digitar). Avisa o server para contabilizar
        -- o puzzle resolvido nas estatisticas da rodada (RoundService, via SolvedPassword).
        local function onCorrectPassword()
            setTextBoxEnabled(false)
            local green = Color3.fromRGB(0, 255, 0)
            spr.target(textBox, 1, 2.5, { TextColor3 = green })
            spr.target(warning, 1, 2.5, { TextColor3 = green })
            fireOfficeServer("SolvedPassword")
        end

        -- Fala a senha digito a digito SO neste cliente (sons locais, nao replicados), com intervalo.
        -- Os Sounds ficam em ctx.Map.Sounds.OfficePuzzleVoice. Yielda (task.wait entre digitos).
        local function playPasswordVoiceLocal(pwd: string)
            local soundsFolder = ctx.Map:FindFirstChild("Sounds")
            local voiceGroup = soundsFolder and soundsFolder:FindFirstChild("OfficePuzzleVoice")
            if not voiceGroup then
                return
            end

            -- Label que mostra os digitos conforme sao falados, concatenando "1-2-3-4".
            local bottomText = resolve(playerGui, "SharedGuis", "GeneralUis", "Frame", "BottomText") :: TextLabel?
            if bottomText then
                bottomText.Text = ""
                bottomText.Visible = true
            end

            local shown = ""
            for i = 1, #pwd do
                -- Espera ANTES de cada digito (inclusive um lead-in antes do primeiro). Isso evita
                -- que o primeiro digito toque no mesmo frame do atendimento/som de Pick (onde ele era
                -- abafado/descartado, parecendo nao tocar); os demais ja tocavam em frames calmos.
                task.wait(DIGIT_INTERVAL)
                local digit = pwd:sub(i, i)
                local sound = voiceGroup:FindFirstChild(digit)
                if sound and sound:IsA("Sound") then
                    sound:Play()
                end
                if bottomText then
                    shown = if shown == "" then digit else shown .. "-" .. digit
                    bottomText.Text = shown
                end
            end

            -- Mantem "1-2-3-4" completo enquanto o ultimo digito termina de tocar e entao esconde.
            task.wait(DIGIT_INTERVAL)
            if bottomText then
                bottomText.Visible = false
                bottomText.Text = ""
            end
        end

        -- Avisa o server para iniciar o puzzle dos telefones (chamado quando a animacao do monitor
        -- termina).
        local function startPhonePuzzleOnServer()
            fireOfficeServer("StartPhonePuzzle")
        end

        -- Conecta os remotes server->client do puzzle (SetPassword/PlayPickSound/AddPuzzleError) de
        -- forma assincrona: o server so os cria apos a barreira de prontidao, entao nao da para
        -- esperar por eles aqui no OnLoad sem travar o MapReady.
        task.spawn(function()
            local comms = ReplicatedStorage:WaitForChild("Comms", 30)
            local office = comms and comms:WaitForChild("Office", 30)
            if not office or not ctx.Map.Parent then
                return
            end
            local setPassword = office:WaitForChild("SetPassword", 30)
            local playPick = office:WaitForChild("PlayPickSound", 30)
            local playVoice = office:WaitForChild("PlayPasswordVoice", 30)
            local addError = office:WaitForChild("AddPuzzleError", 30)
            if not (setPassword and playPick and playVoice and addError) or not ctx.Map.Parent then
                return
            end

            -- Server enviou a senha desta rodada (para validar o que for digitado no monitor).
            ctx.Connections:Connect(ctx.Map, "OfficeSetPassword", setPassword.OnClientEvent, function(pwd)
                if typeof(pwd) == "string" then
                    password = pwd
                end
            end)

            -- Server mandou tocar o som de Pick (atender o telefone) SO neste cliente (nao replicado).
            ctx.Connections:Connect(ctx.Map, "OfficePlayPick", playPick.OnClientEvent, function(pickSound)
                if pickSound and pickSound:IsA("Sound") then
                    pickSound:Play()
                end
            end)

            -- Atendeu o telefone correto: fala a senha digito a digito SO neste cliente (atendente).
            ctx.Connections:Connect(ctx.Map, "OfficePlayVoice", playVoice.OnClientEvent, function(pwd)
                if typeof(pwd) == "string" then
                    task.spawn(playPasswordVoiceLocal, pwd)
                end
            end)

            -- Server contabilizou um erro do puzzle (ex.: timeout do telefone): aplica no monitor.
            ctx.Connections:Connect(ctx.Map, "OfficeAddError", addError.OnClientEvent, function()
                addPuzzleError()
            end)
        end)

        -- Checa a senha digitada quando o player confirma (Enter): acerto deixa o texto verde,
        -- erro treme e conta +1 erro. Ignora apos acertar (unlocked) ou apos falhar.
        ctx.Connections:Connect(ctx.Map, "OfficePasswordCheck", textBox.FocusLost, function(enterPressed)
            if not enterPressed or failed or unlocked or not password then
                return
            end
            if textBox.Text == password then
                unlocked = true
                onCorrectPassword()
            else
                onWrongPassword()
            end
        end)

        ctx.Connections:Connect(ctx.Map, "OfficeManagerPC", prompt.Triggered, function()
            if activated or failed then
                return
            end
            activated = true

            -- Pausa o viewmodel: para o loop de render (liberando a camera) e ESCONDE o modelo do
            -- item, se houver, sem destrui-lo - assim o :Resume no exitMonitor consegue restaura-lo.
            local viewmodel = ctx.GetController("ViewmodelController"):GetViewmodel()
            if viewmodel then
                viewmodel:Pause()
            end

            -- Trava a camera na CFrame da Part de referencia (Cameras.1).
            local camera = workspace.CurrentCamera
            camera.CameraType = Enum.CameraType.Scriptable
            camera.CFrame = cameraPart.CFrame

            -- Libera/exibe o cursor enquanto o player estiver olhando para o monitor.
            UserInputService.MouseBehavior = Enum.MouseBehavior.Default
            UserInputService.MouseIconEnabled = true

            -- Mostra o botao Back para o jogador poder sair do monitor.
            if backButton then
                backButton.Visible = true
            end

            -- Animacoes de entrada do monitor: so tocam na PRIMEIRA vez que o jogador acessa.
            if introPlayed then
                return
            end
            introPlayed = true

            -- Toda a intro (crescimento + glitch) bloqueia a digitacao; libera ao terminar.
            beginBusy()

            -- Com a camera ja posicionada, cresce o TextBox em Y.Scale ate .3 com um spring.
            task.wait(1)
            local size = textBox.Size
            spr.target(textBox, 0.7, 3.5, {
                Size = UDim2.new(size.X.Scale, size.X.Offset, 0.3, 0),
            })

            -- Quando a animacao de crescimento terminar, escreve o aviso com o efeito "Glitch" e, ao
            -- terminar, pede ao server para iniciar o puzzle dos telefones e libera o TextBox.
            spr.completed(textBox, function()
                task.wait(.5)
                showWarningGlitch("Pick the next call", function()
                    startPhonePuzzleOnServer()
                    endBusy()
                end)
            end)
        end)
    end)
end

function Office.OnUnload(ctx)
    --print(string.format("[Office:client] OnUnload (loadId=%d)", ctx.LoadId))

    -- Limpa todas as conexoes registradas para este mapa.
    ctx.Connections:DisconnectAll(ctx.Map)
end

return Office
