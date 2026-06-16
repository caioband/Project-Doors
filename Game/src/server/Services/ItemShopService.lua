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
}

-- Lista de itens renderizados pela loja. Editar aqui para adicionar/remover itens.
local Items: { Item } = {
    { Id = "flashlight", Name = "Flashlight", Price = 50, Icon = "rbxassetid://0" },
    { Id = "lighter", Name = "Lighter", Price = 75, Icon = "rbxassetid://0" },
    { Id = "vitamins", Name = "Vitamins", Price = 120, Icon = "rbxassetid://0" },
    { Id = "crucifix", Name = "Crucifix", Price = 250, Icon = "rbxassetid://0" },
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


-- Retorna o valor atual da moeda do jogador (via leaderstats). nil se nao houver sistema de moeda.
local function GetCurrency(player: Player): IntValue?
    local leaderstats = player:FindFirstChild("leaderstats")
    if not leaderstats then
        return nil
    end
    return leaderstats:FindFirstChild(CURRENCY_NAME) :: IntValue?
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

    local currency = GetCurrency(player)
    if currency then
        if currency.Value < item.Price then
            return { success = false, message = "You don't have enough " .. CURRENCY_NAME .. "." }
        end
        currency.Value -= item.Price
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
