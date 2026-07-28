--!strict
-- ItemShopService
-- Responsavel por:
--   * Garantir a existencia dos Remotes em ReplicatedStorage.Comms.ItemShop (cria caso nao existam)
--   * Fornecer a lista de itens da loja para o cliente (GetItems)
--   * Validar e processar compras vindas do cliente (BuyItem)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local ItemShopService = {}

-- Nome do recurso usado como moeda dentro de leaderstats.
local CURRENCY_NAME = "Coins"

export type Item = {
    Id: string,
    Name: string,
    Price: number,
    Icon: string,
    -- Texto exibido no DetailsContainer quando o item e selecionado.
    Description: string,
    -- Nome do modelo em ReplicatedStorage.Assets.Models.Items usado no ViewportFrame
    -- da tela de detalhes. Opcional: sem ele o viewport fica vazio.
    Model: string?,
}

-- Lista de itens renderizados pela loja. Editar aqui para adicionar/remover itens.
-- Só entra aqui item IMPLEMENTADO de ponta a ponta (efeito da compra + callbacks da Hotbar): um
-- item listado sem implementacao vira dinheiro jogado fora para o jogador. Hoje so a Flashlight
-- tem os dois lados prontos (FlashlightService + HotbarHandlerController).
--
-- Preco da Flashlight: o jogador comeca a sessao com $0 (CurrencyService.STARTING_BALANCE) e uma
-- rodada boa rende ~$150-280 (loot ate ~$180 com a mochila cheia + $50 por puzzle resolvido, ver
-- CollectablesService/RoundService.PUZZLE_REWARD) — mas SO se ele escapar vivo: morrer zera a
-- rodada inteira. $100 deixa a lanterna ao alcance de UMA fuga bem-sucedida: a primeira rodada e
-- jogada no escuro e o objetivo dela e sair vivo com dinheiro para comprar a luz da proxima.
local Items: { Item } = {
    {
        Id = "flashlight",
        Name = "Flashlight",
        Price = 100,
        Icon = "rbxassetid://0",
        Description = "A handheld flashlight. Lights up the room ahead of you while equipped.",
        Model = "Flashlight",
    },
}

-- Indice por Id para consultas rapidas.
local ItemsById: { [string]: Item } = {}
for _, item in ipairs(Items) do
    ItemsById[item.Id] = item
end

-- Itens ja comprados por jogador (evita compra duplicada). [player] = { [itemId] = true }
local OwnedItems: { [Player]: { [string]: boolean } } = {}

local BuyItemRemote: RemoteFunction
local GetItemsRemote: RemoteFunction


-- Garante a hierarquia ReplicatedStorage.Comms.ItemShop e os RemoteFunctions necessarios.
local function EnsureRemotes()
    local comms = ReplicatedStorage:FindFirstChild("Comms")
    if not comms then
        comms = Instance.new("Folder")
        comms.Name = "Comms"
        comms.Parent = ReplicatedStorage
    end

    local itemShopFolder = comms:FindFirstChild("ItemShop")
    if not itemShopFolder then
        itemShopFolder = Instance.new("Folder")
        itemShopFolder.Name = "ItemShop"
        itemShopFolder.Parent = comms
    end

    GetItemsRemote = itemShopFolder:FindFirstChild("GetItems") :: RemoteFunction
    if not GetItemsRemote then
        GetItemsRemote = Instance.new("RemoteFunction")
        GetItemsRemote.Name = "GetItems"
        GetItemsRemote.Parent = itemShopFolder
    end

    BuyItemRemote = itemShopFolder:FindFirstChild("BuyItem") :: RemoteFunction
    if not BuyItemRemote then
        BuyItemRemote = Instance.new("RemoteFunction")
        BuyItemRemote.Name = "BuyItem"
        BuyItemRemote.Parent = itemShopFolder
    end
end


-- Cobra o preco do item. O CurrencyService e o dono do saldo (leaderstats.Coins); sem ele
-- registrado, cai no acesso direto ao leaderstats e, na falta dele tambem, a compra e liberada
-- (nao trava a loja num servidor sem sistema de moeda).
local function TryCharge(player: Player, price: number): boolean
    local CurrencyService = ItemShopService.GetService and ItemShopService.GetService("CurrencyService")
    if CurrencyService then
        return CurrencyService:TrySpend(player, price)
    end

    local leaderstats = player:FindFirstChild("leaderstats")
    local currency = leaderstats and leaderstats:FindFirstChild(CURRENCY_NAME) :: IntValue?
    if not currency then
        return true
    end
    if currency.Value < price then
        return false
    end
    currency.Value -= price
    return true
end


-- Concede o item ao jogador. Ponto central para aplicar o efeito real da compra.
local function GrantItem(player: Player, item: Item)
    OwnedItems[player] = OwnedItems[player] or {}
    OwnedItems[player][item.Id] = true
    -- TODO: aplicar o efeito real da compra (entregar tool, setar atributo, etc.)
end


-- Handler de GetItems: devolve a lista de itens (com flag Owned por jogador) para o cliente renderizar.
local function OnGetItems(player: Player): { any }
    local owned = OwnedItems[player] or {}
    local result = {}
    for _, item in ipairs(Items) do
        table.insert(result, {
            Id = item.Id,
            Name = item.Name,
            Price = item.Price,
            Icon = item.Icon,
            Description = item.Description,
            Model = item.Model,
            Owned = owned[item.Id] == true,
        })
    end
    return result
end


-- Handler de BuyItem: valida e processa a compra. Sempre retorna { success, message }.
local function OnBuyItem(player: Player, itemId: any): { success: boolean, message: string }
    if typeof(itemId) ~= "string" then
        return { success = false, message = "Invalid item." }
    end

    local item = ItemsById[itemId]
    if not item then
        return { success = false, message = "This item does not exist." }
    end

    OwnedItems[player] = OwnedItems[player] or {}
    if OwnedItems[player][item.Id] then
        return { success = false, message = "You already own this item." }
    end

    if not TryCharge(player, item.Price) then
        return { success = false, message = "You don't have enough " .. CURRENCY_NAME .. "." }
    end

    GrantItem(player, item)

    return { success = true, message = "Purchase successful!" }
end


function ItemShopService:Init()
    EnsureRemotes()
end


function ItemShopService:Start()
    GetItemsRemote.OnServerInvoke = OnGetItems
    BuyItemRemote.OnServerInvoke = OnBuyItem

    Players.PlayerRemoving:Connect(function(player)
        OwnedItems[player] = nil
    end)
end


return ItemShopService
