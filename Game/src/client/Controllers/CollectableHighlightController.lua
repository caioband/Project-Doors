-- CollectableHighlightController (client)
-- Brilho de proximidade dos itens coletaveis: ao chegar a HIGHLIGHT_RANGE (18) studs de um item da
-- Folder <MapaAtivo>.CollectableItems, ele comeca a ficar branco (Highlight) e vai ganhando corpo
-- conforme o player se aproxima — do totalmente invisivel (transparencia 1, na borda do alcance)
-- ate MIN_TRANSPARENCY (o estado mais "cheio"; nunca fica opaco, para nao virar um borrao branco
-- por cima do item bem na hora de ler o ProximityPrompt).
--
-- Puramente visual e LOCAL: os Highlights sao criados pelo cliente dentro dos itens (que sao
-- replicados pelo servidor), entao somem sozinhos quando o item e coletado ou o mapa e descarregado.

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local CollectableHighlightController = {}

local LocalPlayer = Players.LocalPlayer

-- Distancia (studs) a partir da qual o item comeca a brilhar.
local HIGHLIGHT_RANGE = 18
-- Transparencia no ponto mais forte do efeito (player colado no item). 1 = invisivel.
local MIN_TRANSPARENCY = 0.75
-- Intervalo (s) entre atualizacoes. Sao poucos itens por mapa, mas nao ha motivo para recalcular
-- distancia todo frame.
local UPDATE_INTERVAL = 0.1

local GLOW_COLOR = Color3.fromRGB(255, 255, 255)

-- Highlight de cada item, criado sob demanda. Chaves fracas: quando o item e coletado/destruido,
-- a entrada sai da tabela sozinha.
local Highlights: { [BasePart]: Highlight } = setmetatable({}, { __mode = "k" }) :: any

local Accumulator = 0


-- Folder dos itens coletaveis do mapa ativo (nil fora de uma rodada / em mapa sem loot).
local function getItemsFolder(): Instance?
    local container = workspace:FindFirstChild("MapInUse")
    local activeMap = container and container:FindFirstChild("ActiveMap")
    return activeMap and activeMap:FindFirstChild("CollectableItems")
end


-- Highlight do item (criado na primeira vez que ele entra no alcance).
local function getHighlight(item: BasePart): Highlight
    local highlight = Highlights[item]
    if highlight and highlight.Parent then
        return highlight
    end

    highlight = Instance.new("Highlight")
    highlight.Adornee = item
    highlight.FillColor = GLOW_COLOR
    highlight.OutlineColor = GLOW_COLOR
    highlight.FillTransparency = 1
    highlight.OutlineTransparency = 1
    -- Occluded: o brilho respeita a geometria (nao atravessa parede/mesa). O item so se revela
    -- quando esta de fato a vista do player.
    highlight.DepthMode = Enum.HighlightDepthMode.Occluded
    highlight.Parent = item

    Highlights[item] = highlight
    return highlight
end


-- Recalcula o brilho de cada item a partir da distancia ate o player.
local function update()
    local folder = getItemsFolder()
    if not folder then
        return
    end

    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?

    for _, item in ipairs(folder:GetChildren()) do
        if item:IsA("BasePart") then
            local transparency = 1

            if root then
                local distance = (item.Position - root.Position).Magnitude
                if distance < HIGHLIGHT_RANGE then
                    -- 0 na borda do alcance -> 1 colado no item.
                    local alpha = 1 - (distance / HIGHLIGHT_RANGE)
                    transparency = 1 - alpha * (1 - MIN_TRANSPARENCY)
                end
            end

            -- Fora do alcance nao criamos Highlight nenhum (evita instanciar por item que o player
            -- nunca chegou perto); se ja existe, ele so fica invisivel.
            local existing = Highlights[item]
            if transparency < 1 or existing then
                local highlight = getHighlight(item)
                highlight.FillTransparency = transparency
                highlight.OutlineTransparency = transparency
            end
        end
    end
end


function CollectableHighlightController:Start()
    RunService.Heartbeat:Connect(function(deltaTime)
        Accumulator += deltaTime
        if Accumulator < UPDATE_INTERVAL then
            return
        end
        Accumulator = 0
        update()
    end)
end


return CollectableHighlightController
