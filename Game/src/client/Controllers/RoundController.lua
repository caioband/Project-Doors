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


-- Mostra a UI de inicio de rodada. Chamada quando a tela esta totalmente preta (fade-in
-- completo). Yielda (o efeito Jitter escreve char a char), por isso o MapController a dispara
-- em uma thread propria para nao atrasar o fade-out.
function RoundController:PlayRoundStartUI()
    local frame, upper, timer = GetRefs()
    if not (frame and upper and timer) then
        warn("[RoundController] GeneralUis.Frame (UpperText/Timer) nao encontrado")
        return
    end

    local generalUis = frame:FindFirstAncestorWhichIsA("ScreenGui")
    if generalUis then
        generalUis.Enabled = true
    end

    -- Estado inicial: mensagem e timer escondidos.
    upper.Visible = false
    timer.Visible = false

    -- 1) Mensagem "Survive..." com efeito Jitter (escreve char a char e treme).
    UIAnimator.ShowText(frame, upper, ROUND_START_MESSAGE, {
        effect = "Jitter",
        onComplete = function()
            -- Efeito aplicado e player ja teleportado: limpa os CharLabels gerados pelo modulo
            -- de efeito e devolve o texto original ao label, visivel.
            ClearCharLabels(frame)
            upper.Text = ROUND_START_MESSAGE
            upper.TextTransparency = 0
            upper.Visible = true

            -- 2) Revela o Timer (passa a ser atualizado pelos ticks do RoundTimer).
            timer.TextTransparency = 0
            timer.Visible = true

            -- 3) Segura a mensagem e entao faz o fade (TextTransparency -> 1) da mensagem JUNTO
            --    com o Timer da GeneralUis.
            task.delay(MESSAGE_HOLD, function()
                local info = TweenInfo.new(FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
                TweenService:Create(upper, info, { TextTransparency = 1 }):Play()
                TweenService:Create(timer, info, { TextTransparency = 1 }):Play()
            end)
        end,
    })
end


function RoundController:Start()
    local comms = ReplicatedStorage:WaitForChild("Comms")
    local roundFolder = comms:WaitForChild("Round")
    RoundTimerRemote = roundFolder:WaitForChild("RoundTimer")

    -- Tick do cronometro da rodada vindo do servidor: atualiza o Timer da GeneralUis com o tempo
    -- restante formatado. Nao altera a visibilidade (quem revela o Timer e o PlayRoundStartUI).
    RoundTimerRemote.OnClientEvent:Connect(function(remaining)
        local _, _, timer = GetRefs()
        if timer then
            timer.Text = TimerFormat.Format(remaining)
        end
    end)
end


return RoundController
