--!strict
-- NavGraph
-- Rede de navegacao de alto nivel para NPCs, construida a partir da pasta AINodes de um mapa
-- (as Parts "Node"). Usada APENAS para PATRULHA: fornece alvos (posicoes de nodes) para o NPC
-- vaguear. O caminho ate cada node — e a perseguicao ao player (Chase/Hunt) — usa o
-- PathfindingService puro dentro do NPCAgent (desvio de obstaculos), sem passar pelos nodes.

local NavGraph = {}
NavGraph.__index = NavGraph

export type NavGraph = typeof(setmetatable({} :: {
	Nodes: { BasePart },
}, NavGraph))

-- Coleta todas as BaseParts filhas de nodesFolder como nodes de patrulha. Aceita nil (grafo vazio).
function NavGraph.new(nodesFolder: Instance?): NavGraph
	local self = setmetatable({}, NavGraph)
	self.Nodes = {}
	if nodesFolder then
		for _, child in ipairs(nodesFolder:GetChildren()) do
			if child:IsA("BasePart") then
				table.insert(self.Nodes, child)
			end
		end
	end
	return self
end

-- Quantidade de nodes carregados.
function NavGraph:Count(): number
	return #self.Nodes
end

-- Node aleatorio (nil se o grafo estiver vazio).
function NavGraph:GetRandomNode(): BasePart?
	if #self.Nodes == 0 then
		return nil
	end
	return self.Nodes[math.random(1, #self.Nodes)]
end

-- Node mais proximo de uma posicao (nil se o grafo estiver vazio).
function NavGraph:GetNearestNode(position: Vector3): BasePart?
	local best: BasePart? = nil
	local bestDist: number? = nil
	for _, node in ipairs(self.Nodes) do
		local d = (node.Position - position).Magnitude
		if not bestDist or d < bestDist then
			best = node
			bestDist = d
		end
	end
	return best
end

-- Node aleatorio a pelo menos minDist studs da posicao dada (evita re-selecionar o node atual
-- durante a patrulha). Se nenhum candidato satisfaz minDist, cai para um node aleatorio qualquer.
function NavGraph:GetRandomNodeAwayFrom(position: Vector3, minDist: number?): BasePart?
	if #self.Nodes == 0 then
		return nil
	end
	local threshold = minDist or 0
	local candidates: { BasePart } = {}
	for _, node in ipairs(self.Nodes) do
		if (node.Position - position).Magnitude >= threshold then
			table.insert(candidates, node)
		end
	end
	if #candidates == 0 then
		return self:GetRandomNode()
	end
	return candidates[math.random(1, #candidates)]
end

return NavGraph
