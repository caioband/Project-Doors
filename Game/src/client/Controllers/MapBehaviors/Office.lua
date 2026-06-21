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

function Office.OnLoad(ctx)
    print(string.format("[Office:client] OnLoad (loadId=%d)", ctx.LoadId))

    local managerPC = resolve(ctx.Map, "Model", "ManagerPC")
    if not managerPC then
        warn("[Office:client] ManagerPC nao encontrado no mapa")
        return
    end

    local prompt = resolve(managerPC, "Keyboard", "Union", "ProximityPrompt") :: ProximityPrompt?
    local cameraPart = resolve(managerPC, "Cameras", "1") :: BasePart?
    local surfaceGui = resolve(managerPC, "SmallMonitor", "Part", "SurfaceGui") :: SurfaceGui?
    local container = surfaceGui and surfaceGui:FindFirstChild("Container") :: Frame?
    local textBox = container and container:FindFirstChild("TextBox") :: TextBox?
    local warning = container and container:FindFirstChild("Warning") :: TextLabel?
    local runText = container and container:FindFirstChild("RunText") :: TextLabel?
    -- SpotLight do monitor (opcional): desligado quando o jogador falha.
    local spotLight = resolve(managerPC, "SmallMonitor", "Part", "SpotLight") :: SpotLight?

    if not (prompt and cameraPart and surfaceGui and container and textBox and warning and runText) then
        warn("[Office:client] Instancias do ManagerPC faltando; abortando bind")
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
                    end,
                })
            end,
        })
    end

    -- Avanca o progresso de erro do puzzle (n/total): deixa o TextBox/Warning mais transparentes
    -- e o Container mais preto; ao esgotar as tentativas (transparencia 1 / container preto)
    -- dispara a sequencia de falha. Usado tanto pela senha errada quanto pelo timeout do telefone.
    local function addPuzzleError()
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
        else
            -- Errou mas ainda tem tentativas: recomeça o loop (o server sorteia novos telefones).
            fireOfficeServer("RestartPhonePuzzle")
        end
    end

    -- Senha digitada errada: treme e contabiliza um erro do puzzle.
    local function onWrongPassword()
        if failed then
            return
        end
        shakeOnWrongPassword()
        addPuzzleError()
    end

    -- Senha digitada correta: deixa o texto do TextBox e do Warning verdes.
    local function onCorrectPassword()
        local green = Color3.fromRGB(0, 255, 0)
        spr.target(textBox, 1, 2.5, { TextColor3 = green })
        spr.target(warning, 1, 2.5, { TextColor3 = green })
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

        -- Com a camera ja posicionada, cresce o TextBox em Y.Scale ate .3 com um spring.
        task.wait(1)
        local size = textBox.Size
        spr.target(textBox, 0.7, 3.5, {
            Size = UDim2.new(size.X.Scale, size.X.Offset, 0.3, 0),
        })

        -- Quando a animacao de crescimento terminar, escreve o aviso com o efeito "Glitch".
        spr.completed(textBox, function()
            task.wait(.5)
            UIAnimator.ShowText(container, warning, "Pick the next call", {
                effect = "Glitch",
                onComplete = function()
                    -- Acabou a animacao: remove os labels de caractere e devolve a visibilidade.
                    clearCharLabels()
                    warning.Text = "Pick the next call"
                    warning.Visible = true

                    -- "Pick the next call": pede ao server para iniciar o puzzle dos telefones.
                    startPhonePuzzleOnServer()
                end,
            })
        end)
    end)
end

function Office.OnUnload(ctx)
    print(string.format("[Office:client] OnUnload (loadId=%d)", ctx.LoadId))

    -- Limpa todas as conexoes registradas para este mapa.
    ctx.Connections:DisconnectAll(ctx.Map)
end

return Office
