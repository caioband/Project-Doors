-- ItemShopController
-- Responsavel por:
--   * Bindar o ProximityPrompt da VotingRoom para abrir a loja
--   * Renderizar os itens vindos do servidor (GetItems) clonando o template
--   * Selecionar um item pelo DetailsButton do card e exibir o DetailsContainer
--     (nome, descricao e o modelo girando no ViewportFrame)
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

-- Preview do item no DetailsContainer: velocidade da rotacao (rad/s) no eixo X e folga da camera
-- em relacao ao tamanho do modelo (1 = modelo preenchendo o viewport).
local SPIN_SPEED = math.rad(60)
local VIEWPORT_FOV = 60
local VIEWPORT_PADDING = 1.6

local ItemShopController = {}

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local ScreenGui: ScreenGui
local Container: Instance
local ScrollingFrame: ScrollingFrame
-- Template de uma linha da lista: Wrapper > ItemShopContainer (ItemName, Price, DetailsButton).
local Template: Frame

local CurrentMoneyLabel: TextLabel
local CloseButton: TextButton

local DetailsContainer: Frame
local DetailsTitle: TextLabel
local DetailsDescription: TextLabel
local DetailsViewport: ViewportFrame
local BuyButton: TextButton

-- Item atualmente selecionado (o que o BuyButton compra) e o card correspondente na lista.
local SelectedItem: any = nil
local SelectedCard: any = nil

-- Loop de rotacao do modelo no ViewportFrame (ativo apenas com o preview na tela).
local SpinConnection: RBXScriptConnection? = nil

-- ScreenGuis ocultadas ao abrir a loja, para restaurar o estado original ao fechar.
local HiddenUIs: { [ScreenGui]: boolean } = {}

local Comms: Folder
local GetItemsRemote: RemoteFunction
local BuyItemRemote: RemoteFunction

local Blur: BlurEffect? = nil
local IsOpen = false

local DistanceConnection: RBXScriptConnection? = nil


-- Confirma se o prompt acionado e o da loja da VotingRoom
-- (VotingRoom.ItemShop.Shop.ProximityPrompt).
-- Comparacao por ancestralidade, sobrevive a rotacao de mapas (MapInUse).
local function IsVotingRoomPrompt(prompt: ProximityPrompt): boolean
    local shop = prompt.Parent
    if not shop or shop.Name ~= "Shop" then
        return false
    end
    local itemShop = shop.Parent
    if not itemShop or itemShop.Name ~= "ItemShop" then
        return false
    end
    local votingRoom = itemShop.Parent
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


-- Resolve a ScreenGui do ChooseComponent SOB DEMANDA. Ela mora dentro do Folder SharedGuis, que o
-- Roblox RE-CLONA inteiro a cada respawn — uma referencia cacheada ficaria obsoleta e o HideOtherUIs
-- esconderia o ChooseComponent NOVO (por nao bater com a referencia velha), deixando as respostas da
-- loja invisiveis ao comprar. Resolvendo ao vivo, a comparacao usa sempre a instancia atual.
local function GetChooseGui(): Instance?
    local sharedGuis = PlayerGui:FindFirstChild("SharedGuis")
    return sharedGuis and sharedGuis:FindFirstChild("ChooseComponent")
end


-- Oculta todas as ScreenGuis (exceto a da loja e a do ChooseComponent), guardando o estado.
local function HideOtherUIs()
    HiddenUIs = {}
    local chooseGui = GetChooseGui()
    for _, gui in ipairs(PlayerGui:GetDescendants()) do
        if gui:IsA("ScreenGui") and gui.Enabled and gui ~= ScreenGui and gui ~= chooseGui then
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


-- Atualiza o texto de moeda da loja a partir do leaderstats do jogador.
local function UpdateCurrency()
    local leaderstats = LocalPlayer:FindFirstChild("leaderstats")
    local coins = leaderstats and leaderstats:FindFirstChild("Coins")
    local value = (coins and coins:IsA("ValueBase") and (coins :: any).Value) or 0
    CurrentMoneyLabel.Text = string.format("You have: $%d", value)
end


-- Habilita/desabilita o botao de compra do DetailsContainer conforme o item selecionado.
local function SetBuyState(owned: boolean)
    BuyButton.Text = owned and "Owned" or "Buy"
    BuyButton.Active = not owned
    BuyButton.AutoButtonColor = not owned
end


-- Marca um card como ja adquirido: o preco vira "Owned" (a nova UI nao tem botao por card,
-- a compra acontece no DetailsContainer) e o botao de compra e travado se o item estiver aberto.
local function MarkOwned(card: any, item)
    item.Owned = true
    card.Price.Text = "Owned"

    if SelectedItem and SelectedItem.Id == item.Id then
        SetBuyState(true)
    end
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


-- Ancora/desancora a PrimaryPart do character. Ao comprar, ancoramos (o player fica parado
-- enquanto a resposta do ChooseComponent esta na tela) e desancoramos no confirmCallback (OK).
local function AnchorCharacter()
    local character = LocalPlayer.Character
    local root = character and (character.PrimaryPart or character:FindFirstChild("HumanoidRootPart"))
    if root and root:IsA("BasePart") then
        root.Anchored = true
    end
end

local function UnanchorCharacter()
    local character = LocalPlayer.Character
    local root = character and (character.PrimaryPart or character:FindFirstChild("HumanoidRootPart"))
    if root and root:IsA("BasePart") then
        root.Anchored = false
    end
end


-- Para a rotacao e esvazia o ViewportFrame (camera + modelo clonado).
local function ClearViewport()
    if SpinConnection then
        SpinConnection:Disconnect()
        SpinConnection = nil
    end
    for _, child in ipairs(DetailsViewport:GetChildren()) do
        child:Destroy()
    end
end


-- Localiza o modelo do item em ReplicatedStorage.Assets.Models.Items.
-- Aceita item.Model (nome explicito) e cai para item.Name como padrao.
local function FindItemModel(item): Instance?
    local assets = ReplicatedStorage:FindFirstChild("Assets")
    local models = assets and assets:FindFirstChild("Models")
    local items = models and models:FindFirstChild("Items")
    if not items then
        return nil
    end
    return items:FindFirstChild(item.Model or item.Name)
end


-- Clona o modelo do item dentro do ViewportFrame, enquadra a camera e comeca a girar no eixo X.
local function RenderPreview(item)
    ClearViewport()

    local template = FindItemModel(item)
    if not template then
        return
    end

    -- Envelopa em um Model para poder centralizar/girar o conjunto com um unico PivotTo,
    -- independente do asset ser uma Part solta ou um Model com varias pecas.
    local holder = Instance.new("Model")
    local clone = template:Clone()

    if clone:IsA("BasePart") then
        clone.Anchored = true
    end
    for _, descendant in ipairs(clone:GetDescendants()) do
        if descendant:IsA("BasePart") then
            descendant.Anchored = true
        end
    end

    clone.Parent = holder
    holder.Parent = DetailsViewport

    -- Centraliza a bounding box do modelo na origem (o pivot passa a ser o centro visual).
    local boundingCFrame, size = holder:GetBoundingBox()
    holder.WorldPivot = boundingCFrame
    holder:PivotTo(CFrame.identity)

    local camera = Instance.new("Camera")
    camera.FieldOfView = VIEWPORT_FOV
    -- Recua o suficiente para o maior eixo do modelo caber no frustum, com folga.
    local distance = (size.Magnitude / 2) / math.tan(math.rad(VIEWPORT_FOV / 2)) * VIEWPORT_PADDING
    camera.CFrame = CFrame.lookAt(Vector3.new(0, 0, math.max(distance, 1)), Vector3.zero)
    camera.Parent = DetailsViewport
    DetailsViewport.CurrentCamera = camera

    local angle = 0
    SpinConnection = RunService.RenderStepped:Connect(function(dt)
        angle += dt * SPIN_SPEED
        holder:PivotTo(CFrame.Angles(angle, 0, 0))
    end)
end


-- Esconde a tela de detalhes e libera o preview.
local function HideDetails()
    SelectedItem = nil
    SelectedCard = nil
    DetailsContainer.Visible = false
    ClearViewport()
end


-- Seleciona um item: preenche nome/descricao, monta o preview e mostra o DetailsContainer.
local function SelectItem(item, card: any)
    SelectedItem = item
    SelectedCard = card

    DetailsTitle.Text = item.Name
    DetailsDescription.Text = item.Description or ""
    SetBuyState(item.Owned == true)

    RenderPreview(item)
    DetailsContainer.Visible = true
end


-- Compra o item selecionado (BuyButton do DetailsContainer).
local function BuySelectedItem()
    local item = SelectedItem
    local card = SelectedCard
    if not item or not card or item.Owned then
        return
    end

    BuyButton.Active = false

    -- Ancora o player enquanto processa a compra e a resposta fica na tela.
    AnchorCharacter()

    local ok, response = pcall(function()
        return BuyItemRemote:InvokeServer(item.Id)
    end)

    if not ok or typeof(response) ~= "table" then
        BuyButton.Active = true
        ChooseComponent:Show({
            type = "Center",
            content = "Something went wrong. Please try again.",
            confirmText = "OK",
            confirmCallback = UnanchorCharacter,
        })
        return
    end

    if response.success then
        MarkOwned(card, item)
        AddToHotbar(item)
        PreloadItemAssets(item)
        UpdateCurrency()
    else
        BuyButton.Active = true
    end

    ChooseComponent:Show({
        type = "Center",
        content = response.message,
        confirmText = "OK",
        confirmCallback = UnanchorCharacter,
    })
end


-- Cria um card de item a partir do template e liga o DetailsButton a selecao.
local function RenderItem(item)
    local wrapper = Template:Clone()
    wrapper.Name = item.Id

    local card = wrapper:FindFirstChild("ItemShopContainer") :: any
    card.ItemName.Text = item.Name
    card.Price.Text = item.Owned and "Owned" or tostring(item.Price)

    wrapper.Visible = true
    wrapper.Parent = ScrollingFrame

    card.DetailsButton.Activated:Connect(function()
        SelectItem(item, card)
    end)
end


-- Limpa os cards renderizados (mantendo o template).
local function ClearItems()
    HideDetails()

    for _, child in ipairs(ScrollingFrame:GetChildren()) do
        if child:IsA("Frame") and child ~= Template then
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

    UpdateCurrency()
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
    -- Solta o preview: sem isso o RenderStepped continuaria girando um modelo fora da tela.
    HideDetails()
    ScreenGui.Enabled = false
    RestoreOtherUIs()
    HideBlur()
    ToggleFreeMouse()

    -- Rede de seguranca: se a loja fechar (Escape/distancia) com uma resposta de compra ainda na
    -- tela, garante que o player nao fique preso ancorado (o desancorar principal e o confirmCallback).
    UnanchorCharacter()
end


function ItemShopController:Start()
    ScreenGui = PlayerGui:WaitForChild("ItemShop")
    local main = ScreenGui:WaitForChild("Main")
    Container = main:WaitForChild("Container")
    ScrollingFrame = Container:WaitForChild("ScrollingFrame")
    Template = ScrollingFrame:WaitForChild("ItemShopWrapper") :: Frame
    CurrentMoneyLabel = Container:WaitForChild("CurrentMoney") :: TextLabel
    CloseButton = Container:WaitForChild("CloseButton") :: TextButton

    DetailsContainer = Container:WaitForChild("DetailsContainer") :: Frame
    DetailsTitle = DetailsContainer:WaitForChild("Label") :: TextLabel
    DetailsDescription = DetailsContainer:WaitForChild("Description") :: TextLabel
    DetailsViewport = DetailsContainer:WaitForChild("ViewportContainer"):WaitForChild("ViewportFrame") :: ViewportFrame
    BuyButton = DetailsContainer:WaitForChild("BuyButton") :: TextButton

    Template.Visible = false
    DetailsContainer.Visible = false
    ScreenGui.Enabled = false

    BuyButton.Activated:Connect(BuySelectedItem)
    CloseButton.Activated:Connect(function()
        self:Close()
    end)

    -- (A ScreenGui do ChooseComponent — que precisa continuar visivel para exibir respostas/erros
    -- do servidor — e resolvida sob demanda em GetChooseGui, pois o SharedGuis re-clona no respawn.)

    Comms = ReplicatedStorage:WaitForChild("Comms")
    local itemShopFolder = Comms:WaitForChild("ItemShop")
    GetItemsRemote = itemShopFolder:WaitForChild("GetItems")
    BuyItemRemote = itemShopFolder:WaitForChild("BuyItem")

    ProximityPromptService.PromptTriggered:Connect(function(prompt)
        if IsVotingRoomPrompt(prompt) then
            self:Open(prompt)
        end
    end)

    -- Fecha a loja com Escape / B (alem do CloseButton da UI).
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
