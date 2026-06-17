-- ItemShopController
-- Responsavel por:
--   * Bindar o ProximityPrompt da VotingRoom para abrir a loja
--   * Renderizar os itens vindos do servidor (GetItems) clonando o template
--   * Enviar pedidos de compra (BuyItem) e exibir erros/respostas via ChooseComponent (Center)
--   * Criar um Blur de fundo ao abrir a loja

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ProximityPromptService = game:GetService("ProximityPromptService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")

local ChooseComponent = require(ReplicatedStorage.Shared.SharedModules.ChooseComponent)

local BLUR_SIZE = 18
local BLUR_TWEEN = TweenInfo.new(0.4)

-- Folga somada ao MaxActivationDistance do prompt antes de fechar a loja automaticamente.
local DISTANCE_BUFFER = 0

local ItemShopController = {}

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local ScreenGui: ScreenGui
local Container: Instance
local ScrollingFrame: ScrollingFrame
local Template: ImageLabel
local ChooseGui: Instance?

-- ScreenGuis ocultadas ao abrir a loja, para restaurar o estado original ao fechar.
local HiddenUIs: { [ScreenGui]: boolean } = {}

local Comms: Folder
local GetItemsRemote: RemoteFunction
local BuyItemRemote: RemoteFunction

local Blur: BlurEffect? = nil
local IsOpen = false

local DistanceConnection: RBXScriptConnection? = nil


-- Confirma se o prompt acionado e o da mesa da VotingRoom.
-- Comparacao por ancestralidade, sobrevive a rotacao de mapas (MapInUse).
local function IsVotingRoomPrompt(prompt: ProximityPrompt): boolean
    local part = prompt.Parent
    if not part or part.Name ~= "Part" then
        return false
    end
    local tablePart = part.Parent
    if not tablePart or tablePart.Name ~= "table" then
        return false
    end
    local votingRoom = tablePart.Parent
    return votingRoom ~= nil and votingRoom.Name == "VotingRoom"
end


-- Alterna o estado do mouse (livre/travado) no Viewmodel ativo.
local function ToggleFreeMouse()
    local getController = ItemShopController.GetController
    if not getController then
        return
    end
    local viewmodelController = getController("ViewmodelController")
    local viewmodel = viewmodelController and viewmodelController:GetViewmodel()
    if viewmodel then
        viewmodel:ToggleFreeMouse()
    end
end


-- Oculta todas as ScreenGuis (exceto a da loja e a do ChooseComponent), guardando o estado.
local function HideOtherUIs()
    HiddenUIs = {}
    for _, gui in ipairs(PlayerGui:GetDescendants()) do
        if gui:IsA("ScreenGui") and gui.Enabled and gui ~= ScreenGui and gui ~= ChooseGui then
            HiddenUIs[gui] = true
            gui.Enabled = false
        end
    end
end


-- Restaura as ScreenGuis ocultadas ao abrir a loja.
local function RestoreOtherUIs()
    for gui in pairs(HiddenUIs) do
        if gui.Parent then
            gui.Enabled = true
        end
    end
    HiddenUIs = {}
end


-- Cria/aciona o blur de fundo.
local function ShowBlur()
    if not Blur then
        Blur = Instance.new("BlurEffect")
        Blur.Size = 0
        Blur:SetAttribute("CreatedByItemShop", true)
        Blur.Parent = Lighting
    end
    TweenService:Create(Blur, BLUR_TWEEN, { Size = BLUR_SIZE }):Play()
end


-- Remove o blur de fundo.
local function HideBlur()
    if not Blur then
        return
    end
    local blur = Blur
    Blur = nil
    local tween = TweenService:Create(blur, BLUR_TWEEN, { Size = 0 })
    tween.Completed:Once(function()
        blur:Destroy()
    end)
    tween:Play()
end


-- Posicao no mundo do alvo (BasePart ou Model).
local function GetWorldPosition(target: Instance): Vector3?
    if target:IsA("BasePart") then
        return target.Position
    elseif target:IsA("Model") then
        return target:GetPivot().Position
    end
    return nil
end


-- Para de observar a distancia ate o alvo.
local function StopDistanceWatch()
    if DistanceConnection then
        DistanceConnection:Disconnect()
        DistanceConnection = nil
    end
end


-- Observa a distancia entre o player e o alvo (Parent do prompt). Fecha a loja se ficar longe.
local function StartDistanceWatch(target: Instance, maxDistance: number)
    StopDistanceWatch()

    DistanceConnection = RunService.Heartbeat:Connect(function()
        local character = LocalPlayer.Character
        local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
        local targetPos = GetWorldPosition(target)

        if not root or not targetPos or not target:IsDescendantOf(game) then
            ItemShopController:Close()
            return
        end

        if (root.Position - targetPos).Magnitude > maxDistance then
            ItemShopController:Close()
        end
    end)
end


-- Marca um card como ja adquirido: botao "Owned" e inativo.
local function MarkOwned(card)
    card.BuyBtn.Text = "Owned"
    card.BuyBtn.Active = false
    card.BuyBtn.AutoButtonColor = false
end


-- Adiciona o item comprado a Hotbar via HotbarHandlerController.
local function AddToHotbar(item)
    local getController = ItemShopController.GetController
    if not getController then
        return
    end
    local hotbarController = getController("HotbarHandlerController")
    if hotbarController then
        hotbarController:AddItem(item)
    end
end


-- Pre-carrega os assets do item comprado (ex.: animacoes da Flashlight) em segundo
-- plano, para que o item ja esteja pronto quando equipado pela primeira vez.
-- Roda em task.spawn para nao travar a UI da loja enquanto baixa.
local function PreloadItemAssets(item)
    local getController = ItemShopController.GetController
    if not getController then
        return
    end
    local hotbarController = getController("HotbarHandlerController")
    if hotbarController then
        task.spawn(function()
            hotbarController:PreloadItemAssets(item)
        end)
    end
end


-- Cria um card de item a partir do template e configura o botao de compra.
local function RenderItem(item)
    local card = Template:Clone()
    card.Name = item.Id

    card.Image = item.Icon
    card.ItemName.Text = item.Name
    card.Price.Text = tostring(item.Price)
    card.Visible = true
    card.Parent = ScrollingFrame

    if item.Owned then
        MarkOwned(card)
        return
    end

    card.BuyBtn.Activated:Connect(function()
        card.BuyBtn.Active = false

        local ok, response = pcall(function()
            return BuyItemRemote:InvokeServer(item.Id)
        end)

        if not ok or typeof(response) ~= "table" then
            card.BuyBtn.Active = true
            ChooseComponent:Show({
                type = "Center",
                content = "Something went wrong. Please try again.",
                confirmText = "OK",
            })
            return
        end

        if response.success then
            MarkOwned(card)
            AddToHotbar(item)
            PreloadItemAssets(item)
        else
            card.BuyBtn.Active = true
        end

        ChooseComponent:Show({
            type = "Center",
            content = response.message,
            confirmText = "OK",
        })
    end)
end


-- Limpa os cards renderizados (mantendo o template).
local function ClearItems()
    for _, child in ipairs(ScrollingFrame:GetChildren()) do
        if child:IsA("ImageLabel") and child ~= Template then
            child:Destroy()
        end
    end
end


-- Busca a lista de itens no servidor e renderiza.
local function PopulateItems()
    local ok, items = pcall(function()
        return GetItemsRemote:InvokeServer()
    end)

    if not ok or typeof(items) ~= "table" then
        ChooseComponent:Show({
            type = "Center",
            content = "Could not load the shop. Please try again.",
            confirmText = "OK",
        })
        return false
    end

    ClearItems()
    for _, item in ipairs(items) do
        RenderItem(item)
    end
    return true
end


function ItemShopController:Open(prompt: ProximityPrompt)
    if IsOpen then
        return
    end
    IsOpen = true

    if not PopulateItems() then
        IsOpen = false
        return
    end

    HideOtherUIs()
    ShowBlur()
    ToggleFreeMouse()
    ScreenGui.Enabled = true

    -- Observa a distancia ate o Parent do prompt para fechar a loja se o player se afastar.
    local target = prompt.Parent
    if target then
        StartDistanceWatch(target, prompt.MaxActivationDistance + DISTANCE_BUFFER)
    end
end


function ItemShopController:Close()
    if not IsOpen then
        return
    end
    IsOpen = false

    StopDistanceWatch()
    ScreenGui.Enabled = false
    RestoreOtherUIs()
    HideBlur()
    ToggleFreeMouse()
end


function ItemShopController:Start()
    ScreenGui = PlayerGui:WaitForChild("ItemShop")
    local frame = ScreenGui:WaitForChild("Frame")
    Container = frame:WaitForChild("Container")
    ScrollingFrame = Container:WaitForChild("ScrollingFrame")
    Template = ScrollingFrame:WaitForChild("ItemShopTemplate")

    Template.Visible = false
    ScreenGui.Enabled = false

    -- ChooseComponent precisa continuar visivel para exibir respostas/erros do servidor.
    local sharedGuis = PlayerGui:FindFirstChild("SharedGuis")
    ChooseGui = sharedGuis and sharedGuis:FindFirstChild("ChooseComponent")

    Comms = ReplicatedStorage:WaitForChild("Comms")
    local itemShopFolder = Comms:WaitForChild("ItemShop")
    GetItemsRemote = itemShopFolder:WaitForChild("GetItems")
    BuyItemRemote = itemShopFolder:WaitForChild("BuyItem")

    ProximityPromptService.PromptTriggered:Connect(function(prompt)
        if IsVotingRoomPrompt(prompt) then
            self:Open(prompt)
        end
    end)

    -- Fecha a loja com Escape / B (nao ha botao de fechar na UI).
    UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed or not IsOpen then
            return
        end
        if input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.ButtonB then
            self:Close()
        end
    end)
end


return ItemShopController
