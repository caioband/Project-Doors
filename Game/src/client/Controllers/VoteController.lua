-- VoteController
-- Responsavel por:
--   * Bindar o ProximityPrompt do botao da VotingRoom (Button.ProximityPrompt)
--   * Ao acionar, pedir ao servidor (ButtonCalled) para iniciar/consultar a votacao
--   * Com o status de votacao, mover a camera (Scriptable) para Cameras.Cam1, mostrar a UI
--     de votacao (StarterGui.Vote) e bindar os botoes das portas
--   * Ao clicar numa porta: seleciona (sem votar ainda) - destaca a porta, anima a camera
--     apontando para ela e mostra o botao Confirm. O voto so e enviado ao clicar em Confirm.
--   * Botao Back (ou Escape/B) sai do modo votacao sem votar.
--   * Refletir as escolhas dos demais jogadores recebidas via BroadcastVote

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local TimerFormat = require(ReplicatedStorage.Shared.SharedModules.TimerFormat)

local FILL_TWEEN = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
-- Animacao da camera ao apontar para a porta selecionada.
local CAMERA_TWEEN = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
-- Fade-in de volume dos AudioPlayers de InitialSounds ao revelar o mapa (fade-out da tela).
local INITIAL_SOUNDS_FADE = TweenInfo.new(1.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local VoteController = {}

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

-- Ordena as portas de forma deterministica (mesma ordem em todos os clientes), para que o
-- indice usado no voto signifique sempre a mesma porta.
local Doors: { Model } = {}
local IsVoting = false

-- ScreenGuis ocultadas ao entrar na votacao, para restaurar o estado original ao sair.
local HiddenUIs: { [ScreenGui]: boolean } = {}

-- Estado do mouse antes da votacao, para restaurar ao sair.
local PrevMouseBehavior: Enum.MouseBehavior? = nil
local PrevMouseIconEnabled: boolean? = nil

local Comms: Folder
local ButtonCalledRemote: RemoteFunction
local VoteRemote: RemoteFunction
local BroadcastVoteRemote: RemoteEvent
local VotingStartedRemote: RemoteEvent
local VotingResetRemote: RemoteEvent
local VotingTimerRemote: RemoteEvent

local VotingRoom: Model
local Cam1: BasePart

-- UI do modo de votacao (StarterGui.Vote). Fica fora do grupo escondido durante a votacao.
local VoteGui: ScreenGui
local ConfirmButton: GuiButton
local BackButton: GuiButton
-- TextLabel do cronometro da votacao (Vote.Timer), atualizado com o tempo restante do servidor.
local TimerLabel: TextLabel

-- Porta atualmente selecionada (aguardando Confirm). nil = nenhuma selecionada.
local SelectedDoorIndex: number? = nil
-- Tween atual da camera (cancelado ao re-selecionar ou sair).
local CameraTween: Tween? = nil

-- ProximityPrompt do botao da sala (desabilitado enquanto vota ou apos ter votado).
local VotePrompt: ProximityPrompt
-- True apos o player confirmar seu voto (mantem o prompt desabilitado).
local HasVoted = false
-- True quando a votacao da rodada ja foi iniciada por algum player (libera os billboards).
local VotingStarted = false

-- Billboards e seus TextLabels (contagem de votos), alinhados por indice com Doors.
local DoorBillboards: { BillboardGui } = {}
local DoorLabels: { TextLabel } = {}


-- Coleta as portas da Folder e as ordena por posicao (Z, depois X) para garantir uma ordem
-- estavel e identica entre todos os clientes.
local function CollectDoors(doorsFolder: Folder): { Model }
    local doors: { Model } = {}
    for _, child in ipairs(doorsFolder:GetChildren()) do
        if child:IsA("Model") and child:FindFirstChild("Highlight") then
            table.insert(doors, child)
        end
    end

    table.sort(doors, function(a, b)
        local pa = a:GetPivot().Position
        local pb = b:GetPivot().Position
        if pa.Z ~= pb.Z then
            return pa.Z < pb.Z
        end
        return pa.X < pb.X
    end)

    return doors
end


-- Aplica visualmente a escolha de uma porta: liga o Highlight da escolhida (anima a
-- FillTransparency para 0) e reseta as demais para o estado desativado.
local function ApplyChoice(chosenIndex: number)
    for index, door in ipairs(Doors) do
        local highlight = door:FindFirstChildWhichIsA("Highlight")
        if not highlight then
            continue
        end

        if index == chosenIndex then
            highlight.Enabled = true
            TweenService:Create(highlight, FILL_TWEEN, { FillTransparency = 0 }):Play()
        else
            highlight.Enabled = false
            highlight.FillTransparency = 1
        end
    end
end


-- Reseta todos os Highlights para o estado desativado (sem nenhuma porta selecionada).
local function ResetChoices()
    for _, door in ipairs(Doors) do
        local highlight = door:FindFirstChildWhichIsA("Highlight")
        if highlight then
            highlight.Enabled = false
            highlight.FillTransparency = 1
        end
    end
end


-- Atualiza o estado do ProximityPrompt: desabilitado enquanto o player vota ou se ja votou.
local function UpdatePromptState()
    if VotePrompt then
        VotePrompt.Enabled = not (IsVoting or HasVoted)
    end
end


-- Liga/desliga os billboards de contagem de votos das portas.
local function SetBillboardsEnabled(enabled: boolean)
    for _, billboard in ipairs(DoorBillboards) do
        billboard.Enabled = enabled
    end
end


-- Reavalia a visibilidade dos billboards: visiveis somente apos a votacao da rodada ter sido
-- iniciada e enquanto o player nao estiver no proprio modo de votacao.
local function RefreshBillboards()
    SetBillboardsEnabled(VotingStarted and not IsVoting)
end


-- Atualiza os TextLabels dos billboards com a contagem de votos por porta (apenas o numero).
local function UpdateBillboards(counts: { number })
    for index, label in ipairs(DoorLabels) do
        label.Text = tostring(counts[index] or 0)
    end
end


-- Atualiza o TextLabel do cronometro com o tempo restante (em segundos) formatado.
local function UpdateTimer(remaining: number?)
    if TimerLabel then
        TimerLabel.Text = TimerFormat.Format(remaining)
    end
end


-- Obtem a instancia do Viewmodel ativo via ViewmodelController (injetado por GetController).
local function GetViewmodel()
    local getController = VoteController.GetController
    if not getController then
        return nil
    end
    local viewmodelController = getController("ViewmodelController")
    return viewmodelController and viewmodelController:GetViewmodel()
end


-- Oculta todas as ScreenGuis da PlayerGui que estiverem visiveis (exceto a propria UI de
-- votacao), guardando o estado. Usa GetDescendants para alcancar ScreenGuis aninhadas.
local function HideAllUIs()
    HiddenUIs = {}
    for _, gui in ipairs(PlayerGui:GetDescendants()) do
        if gui:IsA("ScreenGui") and gui.Enabled and gui ~= VoteGui then
            HiddenUIs[gui] = true
            gui.Enabled = false
        end
    end
end


-- Restaura as ScreenGuis ocultadas ao entrar na votacao.
local function RestoreUIs()
    for gui in pairs(HiddenUIs) do
        if gui.Parent then
            gui.Enabled = true
        end
    end
    HiddenUIs = {}
end


-- Libera o mouse (cursor visivel) para o player conseguir clicar nos botoes das portas,
-- guardando o estado anterior para restaurar ao sair.
local function EnableVoteMouse()
    PrevMouseBehavior = UserInputService.MouseBehavior
    PrevMouseIconEnabled = UserInputService.MouseIconEnabled
    UserInputService.MouseBehavior = Enum.MouseBehavior.Default
    UserInputService.MouseIconEnabled = true
end


-- Restaura o estado do mouse de antes da votacao.
local function RestoreMouse()
    if PrevMouseBehavior then
        UserInputService.MouseBehavior = PrevMouseBehavior
    end
    if PrevMouseIconEnabled ~= nil then
        UserInputService.MouseIconEnabled = PrevMouseIconEnabled
    end
    PrevMouseBehavior = nil
    PrevMouseIconEnabled = nil
end


-- Move a camera para a Cam1 da sala de votacao em modo Scriptable.
local function MoveCameraToVoting()
    local camera = Workspace.CurrentCamera
    if not camera then
        return
    end
    camera.CameraType = Enum.CameraType.Scriptable
    camera.CFrame = Cam1.CFrame
end


-- Cancela a animacao de camera em andamento, se houver.
local function CancelCameraTween()
    if CameraTween then
        CameraTween:Cancel()
        CameraTween = nil
    end
end


-- Anima a camera (a partir da Cam1) para apontar para a porta selecionada.
local function PointCameraAtDoor(index: number)
    local camera = Workspace.CurrentCamera
    local door = Doors[index]
    if not camera or not door then
        return
    end

    CancelCameraTween()

    local doorCFrame = door:GetBoundingBox()
    local targetCFrame = CFrame.lookAt(Cam1.CFrame.Position, doorCFrame.Position)

    CameraTween = TweenService:Create(camera, CAMERA_TWEEN, { CFrame = targetCFrame })
    CameraTween:Play()
end


-- Devolve a camera ao jogador.
local function RestoreCamera()
    CancelCameraTween()
    local camera = Workspace.CurrentCamera
    if not camera then
        return
    end
    camera.CameraType = Enum.CameraType.Custom
end


-- Envia o voto ao servidor para a porta de indice informado.
local function CastVote(doorIndex: number)
    local ok = pcall(function()
        return VoteRemote:InvokeServer(doorIndex)
    end)
    if not ok then
        warn("[VoteController] Falha ao enviar voto.")
    end
end


-- Seleciona uma porta (sem votar): destaca a porta, anima a camera apontando para ela e
-- revela o botao Confirm. O voto so e enviado quando o player clicar em Confirm.
local function SelectDoor(index: number)
    SelectedDoorIndex = index
    ApplyChoice(index)
    PointCameraAtDoor(index)
    ConfirmButton.Visible = true
end


-- Entra no modo de votacao: posiciona a camera, reseta os destaques e aplica a ultima
-- escolha registrada (caso a votacao ja estivesse em andamento).
function VoteController:EnterVoting(status)
    if IsVoting then
        return
    end
    IsVoting = true

    -- Para o loop do viewmodel (que controla a camera todo frame) e esconde o modelo/itens
    -- posicionados, antes de assumir a camera para a votacao.
    local viewmodel = GetViewmodel()
    if viewmodel then
        viewmodel:Pause()
    end

    -- A votacao da rodada esta ativa. Desabilita o prompt enquanto vota e esconde os
    -- billboards de contagem (so reaparecem ao sair do modo votacao).
    VotingStarted = true
    UpdatePromptState()
    RefreshBillboards()

    HideAllUIs()
    EnableVoteMouse()
    MoveCameraToVoting()
    ResetChoices()

    -- Mostra a UI de votacao com o botao Confirm escondido ate o player escolher uma porta.
    -- O Back so aparece para quem esta no modo de votacao.
    SelectedDoorIndex = nil
    ConfirmButton.Visible = false
    BackButton.Visible = true
    VoteGui.Enabled = true
    if TimerLabel then
        TimerLabel.Visible = true
    end

    -- Sincroniza a contagem atual de votos (mesmo com os billboards escondidos agora).
    if status and typeof(status.counts) == "table" then
        UpdateBillboards(status.counts)
    end

    -- Mostra imediatamente o tempo restante da votacao (para quem entra com ela em andamento).
    if status and typeof(status.remaining) == "number" then
        UpdateTimer(status.remaining)
    end

    if status and typeof(status.latestChoice) == "number" then
        ApplyChoice(status.latestChoice)
    end
end


-- Sai do modo de votacao: restaura a camera e os destaques.
function VoteController:ExitVoting()
    if not IsVoting then
        return
    end
    IsVoting = false
    SelectedDoorIndex = nil

    -- Sai do modo de votacao, mas mantem a Vote GUI habilitada para o Timer continuar visivel
    -- a todos durante a votacao/carregamento. Esconde apenas os botoes do modo de votacao.
    ConfirmButton.Visible = false
    BackButton.Visible = false

    -- Restaura a camera ao jogador e so entao retoma o loop do viewmodel (que espera a
    -- camera no tipo Custom), reexibindo o modelo/itens.
    RestoreCamera()
    RestoreMouse()
    RestoreUIs()

    local viewmodel = GetViewmodel()
    if viewmodel then
        viewmodel:Resume()
    end

    ResetChoices()

    -- Reexibe os billboards de contagem (se a votacao da rodada continua ativa) e reavalia
    -- o prompt (fica desabilitado se ja votou).
    RefreshBillboards()
    UpdatePromptState()
end


-- Confirma o voto na porta selecionada (acionado pelo botao Confirm) e sai do modo votacao.
function VoteController:ConfirmVote()
    if not IsVoting or not SelectedDoorIndex then
        return
    end
    CastVote(SelectedDoorIndex)
    HasVoted = true
    self:ExitVoting()
end


-- Reseta o estado local da votacao (acionado pelo servidor ao iniciar uma nova rodada):
-- sai do modo votacao se estiver nele, esconde os billboards, zera a contagem e reabilita
-- o prompt para que a rodada possa ser iniciada novamente.
function VoteController:ResetVoting()
    if IsVoting then
        self:ExitVoting()
    end
    VotingStarted = false
    HasVoted = false
    UpdateBillboards({})
    UpdateTimer(0)
    -- Volta ao lobby: esconde o Timer/Vote GUI ate a proxima votacao comecar.
    if TimerLabel then
        TimerLabel.Visible = false
    end
    VoteGui.Enabled = false
    RefreshBillboards()
    UpdatePromptState()
end


-- Define um texto de status no Timer (usado pelo MapController durante o carregamento do mapa:
-- progresso do preload, "aguardando outros jogadores...", etc.). Garante o Timer visivel a todos.
function VoteController:SetTimerText(text: string)
    if not TimerLabel then
        return
    end
    VoteGui.Enabled = true
    TimerLabel.Visible = true
    TimerLabel.Text = text
end


-- Toca os AudioPlayers de InitialSounds do mapa atual (Workspace.MapInUse.ActiveMap.InitialSounds)
-- ao revelar o mapa. Ignora os marcados com o atributo Ignore == true (ex.: trovoes, tocados sob
-- demanda pelo behavior do mapa). Cada um comeca com Volume 0, da Play e faz tween ate o volume alvo
-- (atributo TargetVolume, ou o Volume ja configurado no Studio; minimo 1 se nao houver).
function VoteController:PlayInitialSounds(fade : number?)
    local mapInUse = Workspace:FindFirstChild("MapInUse")
    local activeMap = mapInUse and mapInUse:FindFirstChild("ActiveMap")
    local folder = activeMap and activeMap:FindFirstChild("InitialSounds")
    if not folder then
        return
    end

    for _, descendant in ipairs(folder:GetDescendants()) do
        if descendant:IsA("AudioPlayer") and descendant:GetAttribute("Ignore") ~= true then
            local target = descendant:GetAttribute("TargetVolume")
            if typeof(target) ~= "number" then
                target = descendant.Volume
            end
            if target <= 0 then
                target = 1
            end

            descendant.Volume = 0
            descendant:Play()
            TweenService:Create(descendant, TweenInfo.new(fade or 5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Volume = target }):Play()
        end
    end
end


-- Cria um frame preto temporario cobrindo a tela e faz fade-in (escurece) seguido de fade-out
-- (clareia). O servidor teleporta os players no meio (tela totalmente preta, apos o fade-in).
-- onFadeInComplete: callback disparado quando a tela esta totalmente preta (fade-in completo,
-- antes do fade-out). E rodado em uma thread propria para NAO yieldar/atrasar o fade-out.
function VoteController:PlayTransition(fadeIn: number?, fadeOut: number?, onFadeInComplete: (() -> ())?)
    local fadeInTime = tonumber(fadeIn) or 5
    local fadeOutTime = tonumber(fadeOut) or 5

    VoteGui.Enabled = true

    -- Frame temporario centralizado cobrindo toda a tela.
    local frame = Instance.new("Frame")
    frame.Name = "Transition"
    frame.AnchorPoint = Vector2.new(0.5, 0.5)
    frame.Position = UDim2.fromScale(0.5, 0.5)
    frame.Size = UDim2.fromScale(1, 1)
    frame.BackgroundColor3 = Color3.new(0, 0, 0)
    frame.BackgroundTransparency = 1
    frame.BorderSizePixel = 0
    frame.ZIndex = 100
    frame.Parent = VoteGui

    -- Ao iniciar o fade-in, esconde imediatamente o texto de progresso de carregamento (Vote.Timer).
    if TimerLabel then
        TimerLabel.Visible = false
    end

    task.spawn(function()
        -- Fade-in: tela escurece ate ficar totalmente preta.
        TweenService:Create(frame, TweenInfo.new(fadeInTime, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), {
            BackgroundTransparency = 0,
        }):Play()
        task.wait(fadeInTime)

        -- Tela totalmente preta (fade-in completo): dispara o callback SEM yieldar o fade-out.
        if onFadeInComplete then
            task.spawn(onFadeInComplete)
        end

        -- Nesse ponto a tela esta preta e o servidor ja esta teleportando os players.
        -- Comecando a revelar o mapa: inicia os InitialSounds (rain etc.) com fade-in de volume.

        -- Fade-out: revela o mapa com os players ja posicionados.
        TweenService:Create(frame, TweenInfo.new(fadeOutTime, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), {
            BackgroundTransparency = 1,
        }):Play()
        self:PlayInitialSounds()
        task.wait(fadeOutTime)

        frame:Destroy()
    end)
end


-- Acionado pelo ProximityPrompt: pede ao servidor para iniciar/consultar a votacao e, com
-- o status retornado, entra no modo de votacao.
function VoteController:OnButtonTriggered()
    if IsVoting then
        return
    end

    local ok, status = pcall(function()
        return ButtonCalledRemote:InvokeServer()
    end)

    if not ok or typeof(status) ~= "table" or status.status ~= "voting" then
        warn("[VoteController] Nao foi possivel iniciar a votacao.")
        return
    end

    self:EnterVoting(status)
end


function VoteController:Start()
    Comms = ReplicatedStorage:WaitForChild("Comms")
    local votationFolder = Comms:WaitForChild("Votation")
    ButtonCalledRemote = votationFolder:WaitForChild("ButtonCalled")
    VoteRemote = votationFolder:WaitForChild("Vote")
    BroadcastVoteRemote = votationFolder:WaitForChild("BroadcastVote")
    VotingStartedRemote = votationFolder:WaitForChild("VotingStarted")
    VotingResetRemote = votationFolder:WaitForChild("VotingReset")
    VotingTimerRemote = votationFolder:WaitForChild("VotingTimer")

    local mapInUse = Workspace:WaitForChild("MapInUse")
    VotingRoom = mapInUse:WaitForChild("VotingRoom")

    local button = VotingRoom:WaitForChild("Button")
    VotePrompt = button.Part:WaitForChild("ProximityPrompt") :: ProximityPrompt

    local cameras = VotingRoom:WaitForChild("Cameras")
    Cam1 = cameras:WaitForChild("Cam1")

    local doorsFolder = VotingRoom:WaitForChild("Doors")
    Doors = CollectDoors(doorsFolder)

    -- Coleta os billboards de contagem de votos (um por porta), inicializa em 0 e os exibe.
    DoorBillboards = {}
    DoorLabels = {}
    for index, door in ipairs(Doors) do
        local buttonPart = door:FindFirstChild("ButtonPart")
        local billboard = buttonPart and buttonPart:FindFirstChildWhichIsA("BillboardGui")
        local label = billboard and billboard:FindFirstChildWhichIsA("TextLabel")
        if billboard and label then
            DoorBillboards[index] = billboard
            DoorLabels[index] = label
            label.Text = "0"
        end
    end
    -- Billboards comecam escondidos: so aparecem quando a votacao da rodada for iniciada.
    RefreshBillboards()

    -- UI do modo de votacao.
    VoteGui = PlayerGui:WaitForChild("Vote")
    ConfirmButton = VoteGui:WaitForChild("Confirm")
    BackButton = VoteGui:WaitForChild("Back")
    TimerLabel = VoteGui:WaitForChild("Timer") :: TextLabel
    VoteGui.Enabled = false
    ConfirmButton.Visible = false
    BackButton.Visible = false
    TimerLabel.Visible = false
    UpdateTimer(0)

    -- Confirm: confirma o voto na porta selecionada. Back: sai sem votar.
    ConfirmButton.Activated:Connect(function()
        self:ConfirmVote()
    end)
    BackButton.Activated:Connect(function()
        self:ExitVoting()
    end)

    -- Bind do ProximityPrompt do botao da sala de votacao.
    VotePrompt.Triggered:Connect(function()
        self:OnButtonTriggered()
    end)

    -- Bind dos botoes das portas: ao clicar, apenas SELECIONA a porta (destaca, anima a
    -- camera e mostra o Confirm). O voto so e enviado ao confirmar.
    for index, door in ipairs(Doors) do
        local buttonPart = door:FindFirstChild("ButtonPart")
        local surfaceGui = buttonPart and buttonPart:FindFirstChildWhichIsA("SurfaceGui")
        local btn = surfaceGui and surfaceGui:FindFirstChild("Btn")
        if btn and btn:IsA("GuiButton") then
            btn.Activated:Connect(function()
                if not IsVoting then
                    return
                end
                SelectDoor(index)
            end)
        end
    end

    -- Recebe do servidor a porta votada e a contagem de votos por porta. Atualiza sempre os
    -- billboards de contagem; o destaque (highlight) so e aplicado quando o player nao esta
    -- votando e ainda nao votou (depois de confirmar o voto, o highlight volta ao estado
    -- inicial e nao deve ser reaplicado pela transmissao do proprio voto).
    BroadcastVoteRemote.OnClientEvent:Connect(function(doorIndex, counts)
        if typeof(counts) == "table" then
            UpdateBillboards(counts)
        end
        if not IsVoting and not HasVoted and typeof(doorIndex) == "number" then
            ApplyChoice(doorIndex)
        end
    end)

    -- A votacao da rodada foi iniciada por algum player: libera os billboards de contagem e
    -- mostra o Timer para TODOS os players (mesmo quem nao esta no modo de votacao). Os botoes
    -- Confirm/Back permanecem escondidos para quem nao esta votando.
    VotingStartedRemote.OnClientEvent:Connect(function(counts)
        VotingStarted = true
        if typeof(counts) == "table" then
            UpdateBillboards(counts)
        end
        VoteGui.Enabled = true
        if not IsVoting then
            ConfirmButton.Visible = false
            BackButton.Visible = false
        end
        TimerLabel.Visible = true
        RefreshBillboards()
    end)

    -- Tick do cronometro vindo do servidor: atualiza o label com o tempo restante formatado.
    -- Ao chegar a zero, fecha o modo de votacao caso o player ainda esteja votando.
    VotingTimerRemote.OnClientEvent:Connect(function(remaining)
        UpdateTimer(remaining)
        if typeof(remaining) == "number" and remaining <= 0 and IsVoting then
            self:ExitVoting()
        end
    end)

    -- Servidor resetou a votacao (nova rodada): volta tudo ao estado inicial.
    VotingResetRemote.OnClientEvent:Connect(function()
        self:ResetVoting()
    end)

    -- Sai do modo de votacao com Escape / B.
    UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed or not IsVoting then
            return
        end
        if input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.ButtonB then
            self:ExitVoting()
        end
    end)
end


return VoteController
