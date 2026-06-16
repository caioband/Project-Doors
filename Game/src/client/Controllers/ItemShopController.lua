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
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")

local ChooseComponent = require(ReplicatedStorage.Shared.SharedModules.ChooseComponent)

local BLUR_SIZE = 18
local BLUR_TWEEN = TweenInfo.new(0.4)

local ItemShopController = {}

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local ScreenGui: ScreenGui
local Container: Instance
local ScrollingFrame: ScrollingFrame
local Template: ImageLabel

local Comms: Folder
local GetItemsRemote: RemoteFunction
local BuyItemRemote: RemoteFunction

local Blur: BlurEffect? = nil
local IsOpen = false


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


-- Cria um card de item a partir do template e configura o botao de compra.
local function RenderItem(item)
    local card = Template:Clone()
    card.Name = item.Id

    card.Image = item.Icon
    card.ItemName.Text = item.Name
    card.Price.Text = tostring(item.Price)
    card.Visible = true
    card.Parent = ScrollingFrame

    card.BuyBtn.Activated:Connect(function()
        card.BuyBtn.Active = false

        local ok, response = pcall(function()
            return BuyItemRemote:InvokeServer(item.Id)
        end)

        card.BuyBtn.Active = true

        if not ok or typeof(response) ~= "table" then
            ChooseComponent:Show({
                type = "Center",
                content = "Something went wrong. Please try again.",
                confirmText = "OK",
            })
            return
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


function ItemShopController:Open()
    if IsOpen then
        return
    end
    IsOpen = true

    if not PopulateItems() then
        IsOpen = false
        return
    end

    ShowBlur()
    ToggleFreeMouse()
    ScreenGui.Enabled = true
end


function ItemShopController:Close()
    if not IsOpen then
        return
    end
    IsOpen = false

    ScreenGui.Enabled = false
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

    Comms = ReplicatedStorage:WaitForChild("Comms")
    local itemShopFolder = Comms:WaitForChild("ItemShop")
    GetItemsRemote = itemShopFolder:WaitForChild("GetItems")
    BuyItemRemote = itemShopFolder:WaitForChild("BuyItem")

    ProximityPromptService.PromptTriggered:Connect(function(prompt)
        if IsVotingRoomPrompt(prompt) then
            self:Open()
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
