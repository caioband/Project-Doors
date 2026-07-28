-- ResultsController (client)
-- Contraparte client das estatisticas de rodada do RoundService. Quando o player e teleportado de
-- volta para a VotingRoom, o server envia as estatisticas da rodada (Comms.Round.RoundResults):
-- puzzles resolvidos, vezes que caiu e tempo total vivo. Este controller entao:
--   1) Preenche os valores nos wrappers da ResultsGUI (ItemValue de cada wrapper), o total ganho
--      na rodada e o PlayerStatus (o dinheiro so e pago a quem escapou vivo).
--   2) Esconde a Hotbar e libera o mouse (cursor visivel), esconde os wrappers e o Continue e
--      liga a ResultsGUI.
--   3) Toca a animacao Cascade "SetupResultsAnim" no Main.
--   4) Ao terminar, deixa os wrappers visiveis e toca "WrapperChildFadeInAnim" em lote nos filhos
--      de cada wrapper (as Frames TimeSurvived/DownedTimes/PuzzlesResolved).
--   5) Ao terminar essa animacao, revela o botao Continue.
--   6) No clique do Continue, esconde a ResultsGUI (e os wrappers) e restaura Hotbar/mouse.
--
-- O Cascade (RuntimeEngine) so roda no cliente; reusamos o MonitorScreenController (wrappers
-- genericos :PlayAnimation / :PlayAnimationBatch) como ponto unico de acesso ao AnimationService.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")

local TimerFormat = require(ReplicatedStorage.Shared.SharedModules.TimerFormat)

local ResultsController = {}

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

-- Escalonamento (s) entre a entrada de cada wrapper na animacao em lote (WrapperChildFadeInAnim).
local WRAPPER_FADE_STAGGER = 0.15

-- Cores do PlayerStatus conforme o desfecho da rodada (escapou vivo x morreu/ficou para tras).
local STATUS_ESCAPED_COLOR = Color3.fromRGB(0, 255, 0)
local STATUS_LOST_COLOR = Color3.fromRGB(255, 40, 40)

-- Wrappers da ListContainer e o nome do Frame filho (a instancia que a WrapperChildFadeInAnim
-- anima e onde ficam ItemName/ItemValue/Icon). A ordem define a entrada escalonada.
local WRAPPERS = {
    { wrapper = "TimeSurvivedWrapper", child = "TimeSurvived" },
    { wrapper = "DownedTimesWrapper", child = "DownedTimes" },
    { wrapper = "PuzzlesResolvedWrapper", child = "PuzzlesResolved" },
    { wrapper = "ItemsCollectedWrapper", child = "ItemsCollected" },
}

-- True enquanto a ResultsGUI esta aberta (guarda callbacks de animacao apos o Continue fechar).
ResultsController.Active = false
-- Conexao atual do botao Continue (religada por exibicao: a ResultsGUI e ResetOnSpawn=true, entao a
-- instancia pode ser re-clonada num respawn).
ResultsController.ContinueConn = nil :: RBXScriptConnection?


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


function ResultsController:_getMonitor()
    local getController = self.GetController
    return getController and getController("MonitorScreenController")
end


function ResultsController:_getViewmodel()
    local getController = self.GetController
    local vc = getController and getController("ViewmodelController")
    return vc and vc:GetViewmodel()
end


-- Preenche o ItemValue de um wrapper (ex.: TimeSurvivedWrapper.TimeSurvived.ItemName.ItemValue).
local function setWrapperValue(listContainer: Instance, wrapperName: string, childName: string, text: string)
    local itemValue = resolve(listContainer, wrapperName, childName, "ItemName", "ItemValue")
    if itemValue and itemValue:IsA("TextLabel") then
        itemValue.Text = text
    end
end


-- Enquanto a ResultsGUI esta aberta a Hotbar fica escondida e o mouse livre (cursor visivel). Ao
-- fechar, restaura Hotbar + mouse travado SOMENTE se o player estiver vivo (mortos/downed mantem o
-- proprio estado de mouse/hotbar gerido pela DeathScreen/spectate).
function ResultsController:_setInteractive(open: boolean)
    local getController = self.GetController
    local hotbar = getController and getController("HotbarHandlerController")
    local viewmodel = self:_getViewmodel()

    if open then
        if hotbar then
            hotbar:SetHotbarEnabled(false)
        end
        if viewmodel then
            viewmodel:SetFreeMouse(true)
        else
            UserInputService.MouseBehavior = Enum.MouseBehavior.Default
            UserInputService.MouseIconEnabled = true
        end
    else
        local character = LocalPlayer.Character
        local alive = character ~= nil and character:GetAttribute("State") == "Alive"
        if alive then
            if hotbar then
                hotbar:SetHotbarEnabled(true)
            end
            if viewmodel then
                viewmodel:SetFreeMouse(false)
            else
                UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
                UserInputService.MouseIconEnabled = false
            end
        end
    end
end


-- Exibe a ResultsGUI com as estatisticas recebidas e conduz a sequencia de animacoes.
function ResultsController:_show(data)
    local gui = PlayerGui:FindFirstChild("ResultsGUI")
    if not gui or not gui:IsA("ScreenGui") then
        warn("[ResultsController] ResultsGUI nao encontrada na PlayerGui")
        return
    end
    local main = gui:FindFirstChild("Main")
    local listContainer = resolve(main, "InfoContainer", "ListContainer")
    local continue = main and main:FindFirstChild("Continue")
    if not (main and listContainer and continue) then
        warn("[ResultsController] Estrutura da ResultsGUI incompleta (Main/ListContainer/Continue)")
        return
    end

    self.Active = true

    -- Distribui os dados da rodada nos wrappers (tempo formatado mm:ss; contagens como numero).
    setWrapperValue(listContainer, "TimeSurvivedWrapper", "TimeSurvived", TimerFormat.Format(data.aliveTime))
    setWrapperValue(listContainer, "DownedTimesWrapper", "DownedTimes", tostring(data.downs or 0))
    setWrapperValue(listContainer, "PuzzlesResolvedWrapper", "PuzzlesResolved", tostring(data.puzzles or 0))
    -- Itens: quantos o player pegou de quantos existiam no mapa.
    setWrapperValue(
        listContainer,
        "ItemsCollectedWrapper",
        "ItemsCollected",
        string.format("%d/%d", data.itemsCollected or 0, data.itemsTotal or 0)
    )

    -- Dinheiro ganho na rodada (itens coletados + bonus dos puzzles). Aparece junto do Continue.
    -- So quem escapou vivo recebe, entao para os demais o servidor manda 0 aqui.
    local totalEarned = resolve(main, "InfoContainer", "TotalEarned")
    if totalEarned and totalEarned:IsA("TextLabel") then
        totalEarned.Text = string.format("Total Earned: $%d", data.earned or 0)
        totalEarned.Visible = false
    end

    -- Desfecho da rodada: e o que explica o "Total Earned: $0" de quem morreu ou ficou para tras.
    local status = resolve(main, "PlayerStatusContainer", "PlayerStatus")
    if status and status:IsA("TextLabel") then
        if data.escaped then
            status.Text = "You Survived"
            status.TextColor3 = STATUS_ESCAPED_COLOR
        else
            status.Text = "You Didn't Escape"
            status.TextColor3 = STATUS_LOST_COLOR
        end
    end

    -- Esconde os wrappers (aparecem so na animacao em lote) e o Continue (aparece so no fim).
    for _, entry in ipairs(WRAPPERS) do
        local wrapper = listContainer:FindFirstChild(entry.wrapper)
        if wrapper then
            wrapper.Visible = false
        end
    end
    continue.Visible = false

    -- Hotbar off + mouse livre e liga a UI.
    self:_setInteractive(true)
    gui.Enabled = true

    -- (Re)liga o Continue a instancia atual: esconde a UI e restaura Hotbar/mouse.
    if self.ContinueConn then
        self.ContinueConn:Disconnect()
    end
    self.ContinueConn = continue.Activated:Connect(function()
        self:_hide()
    end)

    local monitor = self:_getMonitor()

    -- Fim da sequencia: revela o total ganho na rodada e o botao Continue.
    local function revealFooter()
        if totalEarned and totalEarned:IsA("TextLabel") then
            totalEarned.Visible = true
        end
        continue.Visible = true
    end

    -- Revela os wrappers e toca a animacao em lote nos filhos; ao terminar, mostra o rodape.
    local function playWrappersFadeIn()
        if not self.Active or gui.Parent == nil then
            return
        end
        local children: { Instance } = {}
        for _, entry in ipairs(WRAPPERS) do
            local wrapper = listContainer:FindFirstChild(entry.wrapper)
            if wrapper then
                wrapper.Visible = true
                local child = wrapper:FindFirstChild(entry.child)
                if child then
                    table.insert(children, child)
                end
            end
        end

        if not monitor or #children == 0 then
            revealFooter()
            return
        end

        local batchSignal = monitor:PlayAnimationBatch(children, "WrapperChildFadeInAnim", { Stagger = WRAPPER_FADE_STAGGER })
        if batchSignal then
            batchSignal:Connect(function(event)
                if event == "Completed" and self.Active then
                    revealFooter()
                end
            end)
        else
            revealFooter()
        end
    end

    -- Sem Cascade disponivel: mostra tudo direto (fallback).
    if not monitor then
        playWrappersFadeIn()
        return
    end

    -- 1) SetupResultsAnim no Main; ao terminar, 2) fade-in dos wrappers.
    local setupSignal = monitor:PlayAnimation(main, "SetupResultsAnim")
    if setupSignal then
        setupSignal:Connect(function(event)
            if event == "Completed" then
                playWrappersFadeIn()
            end
        end)
    else
        playWrappersFadeIn()
    end
end


-- Esconde a ResultsGUI (e os wrappers) e restaura Hotbar/mouse. Acionado pelo Continue.
function ResultsController:_hide()
    if not self.Active then
        return
    end
    self.Active = false

    if self.ContinueConn then
        self.ContinueConn:Disconnect()
        self.ContinueConn = nil
    end

    local gui = PlayerGui:FindFirstChild("ResultsGUI")
    if gui then
        local main = gui:FindFirstChild("Main")
        local listContainer = resolve(main, "InfoContainer", "ListContainer")
        if listContainer then
            for _, entry in ipairs(WRAPPERS) do
                local wrapper = listContainer:FindFirstChild(entry.wrapper)
                if wrapper then
                    wrapper.Visible = false
                end
            end
        end
        local totalEarned = resolve(main, "InfoContainer", "TotalEarned")
        if totalEarned then
            totalEarned.Visible = false
        end
        local continue = main and main:FindFirstChild("Continue")
        if continue then
            continue.Visible = false
        end
        gui.Enabled = false
    end

    self:_setInteractive(false)
end


function ResultsController:Start()
    local comms = ReplicatedStorage:WaitForChild("Comms")
    local roundFolder = comms:WaitForChild("Round")
    local resultsRemote = roundFolder:WaitForChild("RoundResults")

    resultsRemote.OnClientEvent:Connect(function(data)
        if typeof(data) == "table" then
            -- Em thread propria: o :_show conecta signals do Cascade e nao deve bloquear o remote.
            task.spawn(function()
                self:_show(data)
            end)
        end
    end)
end


return ResultsController
