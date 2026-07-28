--!strict
-- CurrencyService
-- Dono unico do dinheiro do jogador. Responsavel por:
--   * Criar leaderstats.Coins ao entrar (o valor replica sozinho para o cliente)
--   * Conceder recompensas (Award): itens coletados, bonus por puzzle resolvido...
--   * Debitar compras (TrySpend), usado pelo ItemShopService
--
-- O saldo e de SESSAO (nao persiste entre servidores). Para persistir, plugar o ProfileStore
-- (ServerScriptService.Server.SharedModules.ProfileStore) em EnsureLeaderstats/OnPlayerRemoving.

local Players = game:GetService("Players")

local CurrencyService = {}

-- Nome do IntValue dentro de leaderstats. O ItemShopService/ItemShopController leem o MESMO nome.
local CURRENCY_NAME = "Coins"
-- Saldo com que o jogador comeca a sessao. 0 = a primeira rodada e jogada sem nada da loja
-- (e o dinheiro dela paga a Flashlight). Ver o balanceamento em ItemShopService/CollectablesService.
local STARTING_BALANCE = 0


-- Garante player.leaderstats.Coins e devolve o IntValue.
local function EnsureLeaderstats(player: Player): IntValue
    local leaderstats = player:FindFirstChild("leaderstats")
    if not leaderstats then
        leaderstats = Instance.new("Folder")
        leaderstats.Name = "leaderstats"
        leaderstats.Parent = player
    end

    local coins = leaderstats:FindFirstChild(CURRENCY_NAME) :: IntValue?
    if not coins then
        coins = Instance.new("IntValue")
        coins.Name = CURRENCY_NAME
        coins.Value = STARTING_BALANCE
        coins.Parent = leaderstats
    end

    return coins :: IntValue
end


-- Saldo atual do jogador.
function CurrencyService:GetBalance(player: Player): number
    return EnsureLeaderstats(player).Value
end


-- Credita `amount` (arredondado, ignorado se <= 0) e devolve o novo saldo.
function CurrencyService:Award(player: Player, amount: number): number
    if type(amount) ~= "number" or amount ~= amount or amount <= 0 then
        return self:GetBalance(player)
    end

    local coins = EnsureLeaderstats(player)
    coins.Value += math.floor(amount)
    return coins.Value
end


-- Debita `amount` SE houver saldo. Retorna true se a cobranca aconteceu (compra autorizada).
-- Custo <= 0 e considerado gratis (autorizado sem debitar).
function CurrencyService:TrySpend(player: Player, amount: number): boolean
    if type(amount) ~= "number" or amount ~= amount or amount <= 0 then
        return true
    end

    local coins = EnsureLeaderstats(player)
    local cost = math.floor(amount)
    if coins.Value < cost then
        return false
    end

    coins.Value -= cost
    return true
end


function CurrencyService:Init()
    -- Players que ja entraram antes deste Service rodar (boot/hot-reload) + os que entrarem depois.
    for _, player in ipairs(Players:GetPlayers()) do
        EnsureLeaderstats(player)
    end
    Players.PlayerAdded:Connect(EnsureLeaderstats)
end


function CurrencyService:Start() end


return CurrencyService
