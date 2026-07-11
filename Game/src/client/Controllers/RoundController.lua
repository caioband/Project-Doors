-- RoundController
-- Contraparte client do RoundService para a rodada ativa:
--   * Mostra a UI de inicio de rodada na GeneralUis quando a tela fica totalmente preta na
--     transicao para o mapa: escreve a mensagem com efeito "Jitter" na UpperText, revela o
--     Timer e depois esconde a mensagem (animacao) deixando-a transparente
--   * Replica o cronometro da rodada (Comms.Round.RoundTimer), atualizando o Timer da GeneralUis
--
-- UI usada: PlayerGui.SharedGuis.GeneralUis.Frame (filhos UpperText + Timer).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

local TimerFormat = require(ReplicatedStorage.Shared.SharedModules.TimerFormat)
local UIAnimator = require(ReplicatedStorage.ExternalPackages.twinkle)

local RoundController = {}

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

-- Mensagem exibida no inicio da rodada (efeito Jitter na UpperText).
local ROUND_START_MESSAGE = "Survive until the timer reaches 0:00"
-- Mensagem exibida quando o timer zera e a fase de fuga (EscapeArea) comeca (mesmo efeito Jitter).
local ESCAPE_MESSAGE = "Escape area unlocked, proceed to the highlighted point."
-- Tempo (s) que a mensagem fica na tela antes do fade.
local MESSAGE_HOLD = 3
-- Duracao (s) do fade (TextTransparency -> 1) da mensagem e do Timer.
local FADE_TIME = 0.5

local RoundTimerRemote: RemoteEvent


-- Resolve as instancias da GeneralUis no momento do uso. A ScreenGui tem ResetOnSpawn = true,
-- entao as referencias podem ser recriadas; resolvemos sob demanda em vez de cachear.
local function GetRefs(): (Frame?, TextLabel?, TextLabel?)
    local sharedGuis = PlayerGui:FindFirstChild("SharedGuis")
    local generalUis = sharedGuis and sharedGuis:FindFirstChild("GeneralUis")
    local frame = generalUis and generalUis:FindFirstChild("Frame")
    if not frame or not frame:IsA("Frame") then
        return nil, nil, nil
    end
    local upper = frame:FindFirstChild("UpperText")
    local timer = frame:FindFirstChild("Timer")
    if not (upper and upper:IsA("TextLabel") and timer and timer:IsA("TextLabel")) then
        return frame, nil, nil
    end
    return frame, upper, timer
end


-- Remove os TextLabels de caractere gerados pelo efeito de texto do twinkle no container.
local function ClearCharLabels(container: Instance)
    for _, child in container:GetChildren() do
        if child:GetAttribute("CharLabel") then
            child:Destroy()
        end
    end
end


-- Anima uma mensagem na UpperText da GeneralUis com o efeito Jitter (escreve char a char e treme),
-- o mesmo usado no inicio da rodada. Liga a ScreenGui, esconde a UpperText, roda o efeito e, ao
-- terminar, limpa os CharLabels do modulo de efeito, restaura o texto final visivel (transparencia
-- 0) e chama onShown(frame, upper) para o passo seguinte (ex.: revelar/fadear). Yielda (o efeito
-- escreve char a char). Retorna false se as refs da UI faltarem.
local function AnimateUpperMessage(text: string, onShown: ((Frame, TextLabel) -> ())?): boolean
    local frame, upper = GetRefs()
    if not (frame and upper) then
        warn("[RoundController] GeneralUis.Frame (UpperText) nao encontrado")
        return false
    end

    local generalUis = frame:FindFirstAncestorWhichIsA("ScreenGui")
    if generalUis then
        generalUis.Enabled = true
    end

    -- Reseta a transparencia ANTES do efeito: o Jitter clona a UpperText como template p/ cada char
    -- (ver twinkle CharBuilder), herdando o TextTransparency dela. Sem isto, apos o fade-out do fim
    -- da mensagem anterior (round start deixa a UpperText em TextTransparency=1) os char labels
    -- nasceriam invisiveis e a animacao nao apareceria — so o texto final (que forcamos a 0). O
    -- Visible=false esconde so o label base durante o efeito (os char labels sao clones visiveis).
    upper.TextTransparency = 0
    upper.Visible = false
    UIAnimator.ShowText(frame, upper, text, {
        effect = "Jitter",
        onComplete = function()
            ClearCharLabels(frame)
            upper.Text = text
            upper.TextTransparency = 0
            upper.Visible = true
            if onShown then
                onShown(frame, upper)
            end
        end,
    })
    return true
end


-- Faz o fade (TextTransparency -> 1) de um label apos MESSAGE_HOLD segundos.
local function FadeOutAfterHold(label: TextLabel)
    task.delay(MESSAGE_HOLD, function()
        local info = TweenInfo.new(FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
        TweenService:Create(label, info, { TextTransparency = 1 }):Play()
    end)
end


-- Mostra a UI de inicio de rodada. Chamada quando a tela esta totalmente preta (fade-in
-- completo). Yielda (o efeito Jitter escreve char a char), por isso o MapController a dispara
-- em uma thread propria para nao atrasar o fade-out.
function RoundController:PlayRoundStartUI()
    -- 1) Mensagem "Survive..." com efeito Jitter e, ao terminar, revela o Timer e segura/fadeia
    --    a mensagem JUNTO com o Timer da GeneralUis.
    AnimateUpperMessage(ROUND_START_MESSAGE, function(_frame, upper)
        local _, _, timer = GetRefs()
        if timer then
            timer.TextTransparency = 0
            timer.Visible = true
        end
        task.delay(MESSAGE_HOLD, function()
            local info = TweenInfo.new(FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
            TweenService:Create(upper, info, { TextTransparency = 1 }):Play()
            if timer then
                TweenService:Create(timer, info, { TextTransparency = 1 }):Play()
            end
        end)
    end)
end


-- Mostra a mensagem de "area de fuga liberada" quando o timer da rodada zera (RoundState=="Escape").
-- Mesma animacao Jitter do inicio da rodada, mas so na UpperText (o Timer ja esta em 0:00), com
-- fade-out apos o hold. Yielda; chamada em thread propria pelo listener de RoundState.
function RoundController:PlayEscapeUnlockedUI()
    AnimateUpperMessage(ESCAPE_MESSAGE, function(_frame, upper)
        FadeOutAfterHold(upper)
    end)
end


function RoundController:Start()
    local comms = ReplicatedStorage:WaitForChild("Comms")
    local roundFolder = comms:WaitForChild("Round")
    RoundTimerRemote = roundFolder:WaitForChild("RoundTimer")
    local roundStateRemote = roundFolder:WaitForChild("RoundState")
    local escapeTransitionRemote = roundFolder:WaitForChild("EscapeTransition")

    -- Tick do cronometro da rodada vindo do servidor: atualiza o Timer da GeneralUis com o tempo
    -- restante formatado. Nao altera a visibilidade (quem revela o Timer e o PlayRoundStartUI).
    RoundTimerRemote.OnClientEvent:Connect(function(remaining)
        local _, _, timer = GetRefs()
        if timer then
            timer.Text = TimerFormat.Format(remaining)
        end
    end)

    -- Fase da rodada. Ao entrar em "Escape" (timer zerou, fuga liberada), anima a mensagem de
    -- fuga na UpperText. Em thread propria: a animacao Jitter yielda char a char.
    roundStateRemote.OnClientEvent:Connect(function(state)
        if state == "Escape" then
            task.spawn(function()
                RoundController:PlayEscapeUnlockedUI()
            end)
        end
    end)

    -- Transicao de fim de fuga: o servidor manda fazer o fade (in/out) e teleporta os players de
    -- volta para a VotingRoom no meio (tela preta). Reusa a UI de transicao da VoteController, mas
    -- sem tocar os InitialSounds do mapa (estamos revelando a VotingRoom).
    escapeTransitionRemote.OnClientEvent:Connect(function(fadeIn, fadeOut)
        local getController = RoundController.GetController
        local voteController = getController and getController("VoteController")
        if voteController and voteController.PlayTransition then
            voteController:PlayTransition(fadeIn, fadeOut, nil, true)
        end
    end)
end


return RoundController
