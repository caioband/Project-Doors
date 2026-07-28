-- BackpackController (client)
-- Contraparte client do CollectablesService: desenha a mochila na StarterGui.BackpackVolumeGUI.
--   * ProgressFrame.Bar cresce de 0 ate 1 (escala Y) conforme o volume ocupado e a COR faz a
--     transicao de verde -> vermelho no mesmo ritmo
--   * BackpackVolume mostra "Backpack Volume: X/MAX"
--   * BackpackFull (o aviso de que o item nao cabe) aparece por FULL_MESSAGE_TIME e some
--   * A GUI so fica ligada durante a rodada (RoundState "Active"/"Escape")
--
-- Todas as instancias sao resolvidas SOB DEMANDA: a BackpackVolumeGUI pode ser re-clonada num
-- respawn (ResetOnSpawn), o que invalidaria qualquer referencia cacheada. Quando a copia nova
-- aparece na PlayerGui, o estado em memoria e reaplicado (ver o watcher em :Start).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

local BackpackController = {}

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local GUI_NAME = "BackpackVolumeGUI"

-- Duracao (s) do tween da barra (tamanho + cor) a cada atualizacao.
local BAR_TWEEN = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Cores dos extremos da barra: vazia (verde) -> cheia (vermelho).
local COLOR_EMPTY = Color3.fromRGB(0, 255, 0)
local COLOR_FULL = Color3.fromRGB(255, 0, 0)

-- Tempo (s) que o aviso "nao cabe na mochila" fica na tela.
local FULL_MESSAGE_TIME = 2

-- Estado em memoria da mochila (sobrevive ao respawn / re-clone da GUI).
BackpackController.Volume = 0
BackpackController.MaxVolume = 3
BackpackController.Count = 0
-- True enquanto a rodada esta em andamento (a GUI so aparece nesse intervalo).
BackpackController.RoundActive = false
-- Token da exibicao atual do aviso de mochila cheia (invalida o timer anterior se reaparecer).
BackpackController.FullToken = 0

local BackpackUpdateRemote: RemoteEvent? = nil


-- Resolve a ScreenGui da mochila na PlayerGui (nil enquanto nao replicou).
local function getGui(): ScreenGui?
    local gui = PlayerGui:FindFirstChild(GUI_NAME)
    if gui and gui:IsA("ScreenGui") then
        return gui
    end
    return nil
end


-- Redesenha a barra, o texto do volume e o estado (Enabled) da GUI a partir do estado em memoria.
function BackpackController:_apply(animate: boolean)
    local gui = getGui()
    if not gui then
        return
    end

    gui.Enabled = self.RoundActive

    local max = math.max(self.MaxVolume, 1)
    local ratio = math.clamp(self.Volume / max, 0, 1)

    local progressFrame = gui:FindFirstChild("ProgressFrame")
    local bar = progressFrame and progressFrame:FindFirstChild("Bar")
    if bar and bar:IsA("GuiObject") then
        local goal = {
            Size = UDim2.fromScale(1, ratio),
            BackgroundColor3 = COLOR_EMPTY:Lerp(COLOR_FULL, ratio),
        }
        if animate then
            TweenService:Create(bar, BAR_TWEEN, goal):Play()
        else
            bar.Size = goal.Size
            bar.BackgroundColor3 = goal.BackgroundColor3
        end
    end

    local label = gui:FindFirstChild("BackpackVolume")
    if label and label:IsA("TextLabel") then
        label.Text = string.format("Backpack Volume: %d/%d", self.Volume, self.MaxVolume)
    end
end


-- Mostra o aviso de que o item nao cabe e o esconde depois de FULL_MESSAGE_TIME.
function BackpackController:_showFullWarning()
    local gui = getGui()
    local label = gui and gui:FindFirstChild("BackpackFull")
    if not (label and label:IsA("TextLabel")) then
        return
    end

    self.FullToken += 1
    local token = self.FullToken
    label.Visible = true

    task.delay(FULL_MESSAGE_TIME, function()
        -- Outro aviso comecou nesse meio tempo: quem esconde e o timer mais novo.
        if token ~= self.FullToken then
            return
        end
        -- Re-resolve: a GUI pode ter sido re-clonada durante a espera.
        local currentGui = getGui()
        local currentLabel = currentGui and currentGui:FindFirstChild("BackpackFull")
        if currentLabel and currentLabel:IsA("TextLabel") then
            currentLabel.Visible = false
        end
    end)
end


-- Aplica o estado vindo do servidor (volume ocupado, maximo e quantidade de itens).
function BackpackController:_onUpdate(data)
    if typeof(data) ~= "table" then
        return
    end

    self.Volume = tonumber(data.volume) or 0
    self.MaxVolume = tonumber(data.max) or self.MaxVolume
    self.Count = tonumber(data.count) or 0

    self:_apply(true)
end


-- Liga/desliga a UI conforme a fase da rodada. Ao sair da rodada, esconde tambem o aviso de
-- mochila cheia (senao ele reapareceria na proxima vez que a GUI ligasse).
function BackpackController:_setRoundActive(active: boolean)
    self.RoundActive = active

    if not active then
        self.FullToken += 1
        local gui = getGui()
        local label = gui and gui:FindFirstChild("BackpackFull")
        if label and label:IsA("TextLabel") then
            label.Visible = false
        end
    end

    self:_apply(false)
end


function BackpackController:Start()
    local comms = ReplicatedStorage:WaitForChild("Comms")
    local collectables = comms:WaitForChild("Collectables")
    local updateRemote = collectables:WaitForChild("BackpackUpdate") :: RemoteEvent
    local backpackFullRemote = collectables:WaitForChild("BackpackFull") :: RemoteEvent
    BackpackUpdateRemote = updateRemote

    updateRemote.OnClientEvent:Connect(function(data)
        self:_onUpdate(data)
    end)

    backpackFullRemote.OnClientEvent:Connect(function()
        self:_showFullWarning()
    end)

    -- A GUI so aparece durante a rodada (some na votacao/carregamento).
    local roundFolder = comms:WaitForChild("Round")
    local roundStateRemote = roundFolder:WaitForChild("RoundState") :: RemoteEvent
    roundStateRemote.OnClientEvent:Connect(function(state)
        self:_setRoundActive(state == "Active" or state == "Escape")
    end)

    -- Respawn: a BackpackVolumeGUI pode ser re-clonada (volta ao estado do template, Enabled=false
    -- e barra zerada). Quando a copia nova aparece, reaplicamos o estado em memoria e pedimos ao
    -- servidor o valor autoritativo da mochila.
    PlayerGui.DescendantAdded:Connect(function(descendant)
        if descendant:IsA("ScreenGui") and descendant.Name == GUI_NAME then
            task.defer(function()
                self:_apply(false)
                if BackpackUpdateRemote then
                    BackpackUpdateRemote:FireServer()
                end
            end)
        end
    end)

    self:_apply(false)
end


return BackpackController
