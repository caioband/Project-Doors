--!strict
-- CollectablesService
-- Itens coletaveis espalhados pelo mapa (loot da rodada). Responsavel por:
--   * Sortear e spawnar itens nas Parts da Folder <Mapa>.CollectableItemSpawns (nem todo spawn
--     recebe um item: cada item tem a sua propria SpawnChance)
--   * Criar o ProximityPrompt de cada item, com o valor e o volume no ObjectText
--   * Ser a autoridade da MOCHILA: cada player tem um volume maximo (BACKPACK_MAX_VOLUME);
--     coletar so e permitido se o item couber, senao o cliente recebe "BackpackFull"
--   * Reportar o item ao RoundService, que acumula o valor como PENDENTE: o dinheiro so e
--     creditado se o player escapar vivo pela EscapeArea (quem morre perde o que carregava)
--
-- Os modelos vem de ServerStorage.Assets.Models.Items. Cada item tem Value ($), Volume (quanto
-- ocupa da mochila) e SpawnChance (0-1). O padrao esta em `Catalog`, mas ATRIBUTOS de mesmo nome
-- no proprio modelo tem prioridade — da para balancear pelo Studio sem mexer no codigo. O modelo
-- aceita ainda um atributo CFrameOffset (CFrame) com a correcao de pose dele no spawn.
--
-- O mapa e clonado/destruido a cada rodada pelo RoundService, entao os itens (filhos do mapa)
-- somem junto; aqui so zeramos o estado por rodada em :SetupMap.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Players = game:GetService("Players")

local CollectablesService = {}

-- Volume total que a mochila comporta. A UI (StarterGui.BackpackVolumeGUI.BackpackVolume) mostra
-- "Backpack Volume: X/<este numero>" — o cliente recebe o maximo pelo remote, nao o hardcoda.
local BACKPACK_MAX_VOLUME = 3

-- Nome da Folder de spawns dentro do mapa. Cada BasePart dentro dela e um ponto de spawn.
local SPAWNS_FOLDER_NAME = "CollectableItemSpawns"

-- Balanceamento dos itens (padrao; sobrescrito por atributos de mesmo nome no modelo).
--   Value       = dinheiro creditado ao coletar
--   Volume      = quanto ocupa da mochila (BACKPACK_MAX_VOLUME e o teto)
--   SpawnChance = chance (0-1) do item realmente aparecer quando e sorteado para um spawn
-- Itens mais valiosos ocupam mais e aparecem menos: com a mochila em 3, o player escolhe entre
-- 1 item grande ou varios pequenos (o haul maximo fica em ~$180 por rodada).
type ItemConfig = {
    Value: number,
    Volume: number,
    SpawnChance: number,
}

local Catalog: { [string]: ItemConfig } = {
    Fan = { Value = 60, Volume = 1, SpawnChance = 0.75 },
    Monitor = { Value = 110, Volume = 2, SpawnChance = 0.55 },
    Typewriter = { Value = 180, Volume = 3, SpawnChance = 0.35 },
}

-- Configuracao do ProximityPrompt criado em cada item.
local PROMPT_ACTION_TEXT = "Collect"
local PROMPT_HOLD_DURATION = 0.4
local PROMPT_MAX_DISTANCE = 8

-- Alcance (studs) do raycast que procura a superficie sob o marcador de spawn para apoiar o item.
local SURFACE_RAYCAST_DEPTH = 10

-- Comando `spawnitem`: distancia (studs) a frente do personagem onde o item e largado e altura de
-- onde sai o raio que procura o chao (acima da cintura, para pegar tambem mesas na frente).
local SPAWN_IN_FRONT_DISTANCE = 5
local SPAWN_IN_FRONT_RAY_HEIGHT = 3

-- Estado da mochila de cada player na rodada atual.
type Backpack = {
    Volume: number, -- volume ocupado
    Value: number,  -- dinheiro acumulado com os itens desta rodada
    Count: number,  -- quantidade de itens coletados
}

local Backpacks: { [Player]: Backpack } = {}

-- Quantos itens foram efetivamente colocados no mapa da rodada atual (denominador do "n/N" da
-- tela de resultados).
local TotalSpawned = 0

local BackpackUpdateRemote: RemoteEvent
local BackpackFullRemote: RemoteEvent


-- Garante a hierarquia ReplicatedStorage.Comms.Collectables e os Remotes necessarios.
local function EnsureRemotes()
    local comms = ReplicatedStorage:FindFirstChild("Comms")
    if not comms then
        comms = Instance.new("Folder")
        comms.Name = "Comms"
        comms.Parent = ReplicatedStorage
    end

    local folder = comms:FindFirstChild("Collectables")
    if not folder then
        folder = Instance.new("Folder")
        folder.Name = "Collectables"
        folder.Parent = comms
    end

    -- Estado da mochila do player (volume ocupado / maximo / quantidade). O cliente redesenha a
    -- barra de volume a cada evento.
    BackpackUpdateRemote = folder:FindFirstChild("BackpackUpdate") :: RemoteEvent
    if not BackpackUpdateRemote then
        BackpackUpdateRemote = Instance.new("RemoteEvent")
        BackpackUpdateRemote.Name = "BackpackUpdate"
        BackpackUpdateRemote.Parent = folder
    end

    -- Tentativa de pegar um item que nao cabe: o cliente mostra o aviso "BackpackFull" por 2s.
    BackpackFullRemote = folder:FindFirstChild("BackpackFull") :: RemoteEvent
    if not BackpackFullRemote then
        BackpackFullRemote = Instance.new("RemoteEvent")
        BackpackFullRemote.Name = "BackpackFull"
        BackpackFullRemote.Parent = folder
    end
end


-- Folder dos modelos de item (ServerStorage.Assets.Models.Items). nil se a hierarquia nao existir.
local function GetItemsFolder(): Instance?
    local assets = ServerStorage:FindFirstChild("Assets")
    local models = assets and assets:FindFirstChild("Models")
    return models and models:FindFirstChild("Items")
end


-- Config de um item: o padrao do Catalog com os atributos do modelo por cima (Value/Volume/
-- SpawnChance authorados no Studio ganham). Retorna nil se o item nao estiver no Catalog e nem
-- tiver atributos (modelo solto na pasta que nao deve virar loot).
local function GetItemConfig(model: Instance): ItemConfig?
    local base = Catalog[model.Name]

    local value = model:GetAttribute("Value")
    local volume = model:GetAttribute("Volume")
    local chance = model:GetAttribute("SpawnChance")

    if not base and not (typeof(value) == "number" and typeof(volume) == "number") then
        return nil
    end

    return {
        Value = if typeof(value) == "number" then value else (base :: ItemConfig).Value,
        Volume = if typeof(volume) == "number" then volume else (base :: ItemConfig).Volume,
        SpawnChance = if typeof(chance) == "number" then chance else (base :: ItemConfig).SpawnChance,
    }
end


-- Lista os modelos de item elegiveis (os que tem config valida) da pasta de assets.
local function CollectItemTemplates(): { { Model: Instance, Config: ItemConfig } }
    local result = {}
    local folder = GetItemsFolder()
    if not folder then
        warn("[CollectablesService] ServerStorage.Assets.Models.Items nao encontrado; sem loot.")
        return result
    end

    for _, child in ipairs(folder:GetChildren()) do
        local config = GetItemConfig(child)
        if config then
            table.insert(result, { Model = child, Config = config })
        end
    end
    return result
end


-- Mochila do player na rodada atual (criada sob demanda).
local function GetBackpack(player: Player): Backpack
    local backpack = Backpacks[player]
    if not backpack then
        backpack = { Volume = 0, Value = 0, Count = 0 }
        Backpacks[player] = backpack
    end
    return backpack
end


-- Envia o estado atual da mochila para o dono (o cliente atualiza a barra de volume).
local function SendBackpackUpdate(player: Player)
    if not BackpackUpdateRemote then
        return
    end
    local backpack = GetBackpack(player)
    BackpackUpdateRemote:FireClient(player, {
        volume = backpack.Volume,
        max = BACKPACK_MAX_VOLUME,
        count = backpack.Count,
        value = backpack.Value,
    })
end


-- Texto do ObjectText do prompt: nome do item com o valor e o volume que ele ocupa.
local function BuildObjectText(name: string, config: ItemConfig): string
    return string.format("%s  |  $%d  |  Vol %d", name, config.Value, config.Volume)
end


-- Coleta de fato: debita o volume, reporta ao RoundService e destroi o item do mapa.
-- O DINHEIRO NAO E CREDITADO AQUI: o valor fica pendente e so vira saldo se o player escapar vivo
-- pela EscapeArea (o pagamento acontece no RoundService, ao fim da fase de fuga). Quem morre ou
-- fica para tras perde o que carregava.
local function Collect(player: Player, item: BasePart, config: ItemConfig)
    local backpack = GetBackpack(player)
    backpack.Volume += config.Volume
    backpack.Count += 1
    backpack.Value += config.Value

    local getService = CollectablesService.GetService

    -- Estatisticas da rodada (itens coletados + o valor que sera pago se ele escapar).
    local RoundService = getService and getService("RoundService")
    if RoundService and RoundService.AddItemCollected then
        RoundService:AddItemCollected(player, config.Value)
    end

    item:Destroy()
    SendBackpackUpdate(player)
end


-- Handler do prompt de um item. Recusa se o player nao estiver vivo ou se o item nao couber na
-- mochila (nesse caso o cliente mostra o aviso de mochila cheia).
local function OnPromptTriggered(player: Player, item: BasePart, config: ItemConfig)
    -- Item ja coletado por outro player no mesmo frame (o prompt ainda existia do lado de la).
    if not item.Parent then
        return
    end

    local character = player.Character
    if not character or character:GetAttribute("State") ~= "Alive" then
        return
    end

    local backpack = GetBackpack(player)
    if backpack.Volume + config.Volume > BACKPACK_MAX_VOLUME then
        if BackpackFullRemote then
            BackpackFullRemote:FireClient(player)
        end
        return
    end

    Collect(player, item, config)
end


-- Altura (Y do mundo) em que a base do item deve ficar: a superficie logo abaixo de `origin`
-- (mesa, chao, prateleira...), achada com um raycast para baixo. `fallbackY` e usado quando o
-- raio nao acha nada (ex.: marcador no ar).
local function FindRestingY(origin: Vector3, fallbackY: number, ignore: { Instance }): number
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = ignore

    local result = workspace:Raycast(origin, Vector3.new(0, -SURFACE_RAYCAST_DEPTH, 0), params)
    if result then
        return result.Position.Y
    end
    return fallbackY
end


-- Altura (no MUNDO) da metade da caixa do item ja orientado. Nao da para usar `size.Y / 2` direto
-- porque o CFrameOffset do modelo pode deita-lo/vira-lo, e ai quem fica na vertical e outro eixo.
-- Projeta as tres semiextensoes no eixo Y do mundo.
local function WorldHalfHeight(cframe: CFrame, size: Vector3): number
    local right, up, look = cframe.RightVector, cframe.UpVector, cframe.LookVector
    return 0.5 * (math.abs(right.Y) * size.X + math.abs(up.Y) * size.Y + math.abs(look.Y) * size.Z)
end


-- Coloca um item no mundo: X/Z vem de `position`, a base fica apoiada em `restingY`, com uma
-- rotacao aleatoria em Y (variedade visual), e cria o ProximityPrompt de coleta.
local function SpawnItemAt(position: Vector3, template: Instance, config: ItemConfig, parent: Instance, restingY: number)
    local clone = template:Clone()
    if not clone:IsA("BasePart") then
        -- Suporte a Models: o codigo abaixo precisa de uma BasePart para posicionar/ancorar.
        warn(string.format("[CollectablesService] Item '%s' nao e uma BasePart; ignorado.", template.Name))
        clone:Destroy()
        return false
    end

    local item = clone :: BasePart
    item.Anchored = true

    -- Correcao autorada por modelo (atributo CFrameOffset no template, opcional): entra DEPOIS do
    -- yaw aleatorio, entao vale no referencial do proprio item — deitar/virar o modelo continua
    -- valendo com qualquer rotacao sorteada, e um deslocamento nela ajusta o item em relacao ao
    -- marcador. Sem o atributo, e identidade.
    local offset = template:GetAttribute("CFrameOffset")
    if typeof(offset) ~= "CFrame" then
        offset = CFrame.identity
    end

    local yaw = math.random() * math.pi * 2
    local oriented = CFrame.new(position.X, restingY, position.Z)
        * CFrame.Angles(0, yaw, 0)
        * offset

    -- Sobe pela metade da altura da caixa JA ORIENTADA para a base encostar na superficie.
    item.CFrame = oriented + Vector3.new(0, WorldHalfHeight(oriented, item.Size), 0)

    -- Guarda o balanceamento no proprio item (util para depurar no Studio durante a rodada).
    item:SetAttribute("Value", config.Value)
    item:SetAttribute("Volume", config.Volume)

    local prompt = Instance.new("ProximityPrompt")
    prompt.ActionText = PROMPT_ACTION_TEXT
    prompt.ObjectText = BuildObjectText(template.Name, config)
    prompt.HoldDuration = PROMPT_HOLD_DURATION
    prompt.MaxActivationDistance = PROMPT_MAX_DISTANCE
    prompt.RequiresLineOfSight = false
    prompt.Parent = item

    prompt.Triggered:Connect(function(player)
        OnPromptTriggered(player, item, config)
    end)

    item.Parent = parent
    return true
end


-- Zera a mochila de todos os players (inicio de rodada) e avisa os clientes para resetarem a barra.
local function ResetBackpacks()
    Backpacks = {}
    for _, player in ipairs(Players:GetPlayers()) do
        SendBackpackUpdate(player)
    end
end


-- Prepara os coletaveis de um mapa recem-carregado: zera as mochilas da rodada e sorteia um item
-- para cada Part da Folder CollectableItemSpawns. Cada spawn escolhe um item ao acaso e so o
-- coloca se passar na SpawnChance dele — por isso nem todo spawn fica com item.
-- Retorna quantos itens foram colocados. Sem a Folder no mapa, e um no-op silencioso.
function CollectablesService:SetupMap(map: Model): number
    ResetBackpacks()
    TotalSpawned = 0

    local spawnsFolder = map:FindFirstChild(SPAWNS_FOLDER_NAME)
    if not spawnsFolder then
        return 0
    end

    local templates = CollectItemTemplates()
    if #templates == 0 then
        return 0
    end

    -- Container dos itens colocados: filho do mapa, entao morre junto com ele no UnloadMap.
    -- Se o mesmo mapa for preparado duas vezes, a leva anterior sai antes (nada de itens dobrados).
    local previous = map:FindFirstChild("CollectableItems")
    if previous then
        previous:Destroy()
    end

    local container = Instance.new("Folder")
    container.Name = "CollectableItems"
    container.Parent = map

    -- O raycast que procura a superficie ignora os proprios marcadores (invisiveis) e os itens ja
    -- colocados, senao um item apoiaria sobre o outro.
    local ignore = { spawnsFolder, container }

    for _, spawnPart in ipairs(spawnsFolder:GetChildren()) do
        if spawnPart:IsA("BasePart") then
            local pick = templates[math.random(1, #templates)]
            if math.random() <= pick.Config.SpawnChance then
                -- Os marcadores sao autorados APOIADOS na superficie: o raio sai do topo deles e
                -- a face de baixo e o fallback quando nao ha nada abaixo.
                local half = spawnPart.Size.Y * 0.5
                local restingY = FindRestingY(
                    spawnPart.Position + Vector3.new(0, half, 0),
                    spawnPart.Position.Y - half,
                    ignore
                )
                if SpawnItemAt(spawnPart.Position, pick.Model, pick.Config, container, restingY) then
                    TotalSpawned += 1
                end
            end
        end
    end

    print(string.format("[CollectablesService] %d item(ns) spawnado(s) em '%s'.", TotalSpawned, map.Name))
    return TotalSpawned
end


-- Quantos itens existem no mapa da rodada atual (o "N" do "n/N" da tela de resultados).
function CollectablesService:GetTotalItems(): number
    return TotalSpawned
end


-- Nomes dos itens disponiveis (para mensagens de erro / autocomplete de comando).
function CollectablesService:GetItemNames(): { string }
    local names = {}
    for _, entry in ipairs(CollectItemTemplates()) do
        table.insert(names, entry.Model.Name)
    end
    table.sort(names)
    return names
end


-- Spawna UM item na frente do player, funcional (prompt, volume, valor) como qualquer outro do
-- mapa. Usado pelo comando `spawnitem` do Cmdr para testar coleta sem depender do sorteio.
-- `itemName` aceita o nome do modelo (case-insensitive); nil ou "random" sorteia um.
-- Retorna (ok, mensagem) — a mensagem e o retorno do comando.
function CollectablesService:SpawnItemInFront(player: Player, itemName: string?): (boolean, string)
    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
    if not root then
        return false, string.format("%s nao tem personagem no momento.", player.Name)
    end

    local templates = CollectItemTemplates()
    if #templates == 0 then
        return false, "Nenhum item valido em ServerStorage.Assets.Models.Items."
    end

    -- Resolve o item pedido (ou sorteia).
    local pick
    if itemName == nil or itemName == "" or itemName:lower() == "random" then
        pick = templates[math.random(1, #templates)]
    else
        local wanted = itemName:lower()
        for _, entry in ipairs(templates) do
            if entry.Model.Name:lower() == wanted then
                pick = entry
                break
            end
        end
        if not pick then
            return false, string.format(
                "Item '%s' nao existe. Disponiveis: %s (ou 'random').",
                itemName,
                table.concat(self:GetItemNames(), ", ")
            )
        end
    end

    -- Container: o mesmo do mapa ativo (some no UnloadMap). Fora de uma rodada nao ha mapa, entao
    -- o item vai solto na Workspace e fica ate alguem pegar/limpar.
    local container: Instance = workspace
    local mapInUse = workspace:FindFirstChild("MapInUse")
    local activeMap = mapInUse and mapInUse:FindFirstChild("ActiveMap")
    local mapContainer = activeMap and activeMap:FindFirstChild("CollectableItems")
    if mapContainer then
        container = mapContainer
    end

    -- Ponto de largada: SPAWN_IN_FRONT_DISTANCE studs a frente do personagem, apoiado no que
    -- houver abaixo (chao/mesa). O raio ignora o proprio personagem e os itens ja colocados —
    -- mas NUNCA o `container` quando ele e a propria Workspace (o fallback de fora de rodada),
    -- senao ignoraria o mundo inteiro e o item ficaria flutuando na altura da cintura.
    local ignore: { Instance } = { character }
    if mapContainer then
        table.insert(ignore, mapContainer)
    end

    local dropPoint = root.Position + root.CFrame.LookVector * SPAWN_IN_FRONT_DISTANCE
    local restingY = FindRestingY(
        dropPoint + Vector3.new(0, SPAWN_IN_FRONT_RAY_HEIGHT, 0),
        dropPoint.Y,
        ignore
    )

    if not SpawnItemAt(dropPoint, pick.Model, pick.Config, container, restingY) then
        return false, string.format("Falha ao spawnar '%s' (o modelo precisa ser uma BasePart).", pick.Model.Name)
    end

    -- Entra na contagem da rodada para o "itens pegos / itens no mapa" da tela de resultados
    -- continuar coerente ao coletar este item.
    TotalSpawned += 1

    return true, string.format(
        "'%s' ($%d, vol %d) spawnado na frente de %s%s.",
        pick.Model.Name,
        pick.Config.Value,
        pick.Config.Volume,
        player.Name,
        if mapContainer then "" else " (fora de rodada: solto na Workspace)"
    )
end


-- Estado da mochila de um player (itens coletados e o valor acumulado na rodada).
function CollectablesService:GetPlayerStats(player: Player): { count: number, value: number, volume: number }
    local backpack = GetBackpack(player)
    return { count = backpack.Count, value = backpack.Value, volume = backpack.Volume }
end


-- Volume maximo da mochila (o cliente recebe pelo remote; exposto aqui para outros services).
function CollectablesService:GetMaxVolume(): number
    return BACKPACK_MAX_VOLUME
end


function CollectablesService:Init()
    EnsureRemotes()
end


function CollectablesService:Start()
    Players.PlayerRemoving:Connect(function(player)
        Backpacks[player] = nil
    end)

    -- Late-joiner / respawn: o cliente pede o estado atual da mochila ao (re)montar a UI.
    BackpackUpdateRemote.OnServerEvent:Connect(function(player)
        SendBackpackUpdate(player)
    end)
end


return CollectablesService
