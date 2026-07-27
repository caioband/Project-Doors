--!strict
-- FootstepSounds (Shared)
-- Catalogo de IDs de som de passos por material do chao (Enum.Material), com suporte a
-- MaterialVariant. O FootstepController sorteia uma variacao a cada passo para nao soar repetitivo.
--
-- Cada material pode ser declarado de duas formas:
--   1) Lista simples de variacoes (sem MaterialVariant):
--          [Enum.Material.Wood] = { 0, 0 },
--   2) Tabela com Default + Variants (por MaterialVariant):
--          [Enum.Material.Concrete] = {
--              Default = { 0, 0 },                 -- usado quando nao ha variant (ou ela nao casa)
--              Variants = {
--                  ["CrackedConcrete"] = { 0, 0 }, -- nome de BasePart.MaterialVariant -> variacoes
--                  ["WetConcrete"]     = { 0, 0 },
--              },
--          },
-- Resolucao: variant especifica -> Default do material -> DefaultMaterial.
--
-- Superficies customizadas (FootstepSounds.Custom): independem do Enum.Material. Se a BasePart que o
-- raycast do chao colidir tiver o atributo "CustomFootstep" (string), seu valor e a chave em Custom e
-- TEM PRIORIDADE sobre material/variant. Sao carregadas junto com os sons de material (GetAllIds).
--
-- IMPORTANTE: os IDs abaixo sao placeholders (0). Troque-os pelos asset ids reais dos sons de
-- passos do jogo. Enquanto estiverem em 0, o material e tratado como "sem som" (nada toca).

local FootstepSounds = {}

export type AssetId = number
export type MaterialEntry = {
	Default: { AssetId }?,
	Variants: { [string]: { AssetId } }?,
}
-- Cada material pode ser uma lista simples OU uma MaterialEntry (com Variants).
export type SoundEntry = { AssetId } | MaterialEntry

-- Parametros globais de reproducao dos passos (usados pelo FootstepController).
FootstepSounds.Config = {
	-- Volume de cada passo.
	Volume = 0.5,
	-- Normalizacao de duracao: cada passo e ajustado (via PlaybackSpeed) para tocar por
	-- NormalizedDuration segundos, independentemente do tamanho do arquivo de audio e da velocidade
	-- do personagem. Como a cadencia dos passos e ditada pela duracao do som, isso deixa todos os
	-- materiais com o mesmo ritmo. PlaybackSpeed de cada som = TimeLength / NormalizedDuration.
	NormalizedDuration = 0.35,
	-- Atenuacao 3D do Sound (fica parented no HumanoidRootPart).
	RollOffMaxDistance = 35,

	-- Cadencia: intervalo (s) entre passos, calculado pela velocidade horizontal da rootpart.
	--   interval = BaseStepInterval * BaseStepSpeed / velocidadeAtual   (limitado por Min/Max)
	-- Quanto mais rapido o personagem, menor o intervalo (mais passos/s). Combina com o gate de
	-- "um som por vez": a cadencia efetiva e o maior entre o intervalo e a duracao do som.
	BaseStepInterval = 0.45,
	-- Velocidade (studs/s) de referencia para BaseStepInterval (WalkSpeed padrao do Roblox = 16).
	BaseStepSpeed = 16,
	-- Limites do intervalo calculado (evita passos rapidos/lentos demais em velocidades extremas).
	MinStepInterval = 0.2,
	MaxStepInterval = 0.8,
}

-- Parametros do sistema de passos por KEYFRAME (server-side, FootstepService). Ao contrario do
-- Config acima (cadencia por timer, no client), aqui a cadencia vem dos KeyframeEvents "Steps"
-- das proprias animacoes de andar/correr, e o som e emitido por um AudioEmitter que e redirecionado
-- para o pe que acabou de pisar. Os asset ids sao OS MESMOS (FootstepSounds.Sounds/Custom).
FootstepSounds.EmitterConfig = {
	-- Nome do AudioEmitter criado dentro do pe (o client usa para mutar o proprio passo).
	EmitterName = "FootstepEmitter",
	-- Nome do AudioPlayer (filho do emitter) que toca cada passo.
	PlayerName = "FootstepPlayer",
	-- Grupo de interacao: precisa casar com o do AudioListener do personagem
	-- (AudioListenerController usa "General").
	AudioInteractionGroup = "General",
	-- Volume de cada passo.
	Volume = 0.5,
	-- Tom/velocidade do passo. 1 = duracao original do asset (a cadencia ja vem da animacao,
	-- entao NAO normalizamos a duracao como no sistema por timer).
	PlaybackSpeed = 1,
	-- Atenuacao 3D: audivel em cheio ate RollOffMinDistance e some em RollOffMaxDistance.
	RollOffMinDistance = 5,
	RollOffMaxDistance = 35,
	-- Intervalo minimo (s) entre dois passos do MESMO pe. Protege contra o marker disparar em
	-- duplicidade (ex.: duas tracks replicadas da mesma animacao no server).
	MinSideInterval = 0.12,
}

-- Quanto BARULHO cada passo faz para a IA (NoiseService/FootstepService). Nao tem relacao com o
-- volume que os jogadores ouvem: e o raio, em studs, em que um NPC que caca por som pode perceber
-- o passo.
--
-- O raio vem da VELOCIDADE horizontal do personagem no instante do passo, nao da animacao — assim
-- nao acoplamos aos asset ids do HumanoidController e o agachado (WalkSpeed 3) fica naturalmente
-- quase mudo:
--     radius = clamp(BaseRadius * velocidade / BaseSpeed, MinRadius, MaxRadius)
-- Com os valores abaixo: andar (8) ~= 28, correr (20) ~= 55, agachado (3) ~= 10.
FootstepSounds.NoiseConfig = {
	-- Raio de referencia, na velocidade BaseSpeed.
	BaseRadius = 28,
	-- Velocidade (studs/s) de referencia (WalkSpeed padrao do HumanoidController).
	BaseSpeed = 8,
	-- Limites do raio calculado.
	MinRadius = 6,
	MaxRadius = 55,
}

-- Material usado quando o material atual nao tem entrada propria.
FootstepSounds.DefaultMaterial = Enum.Material.Plastic

-- Enum.Material -> SoundEntry.  (0 = placeholder a ser substituido pelo id real)
FootstepSounds.Sounds = {
	-- Genericos / construidos
	[Enum.Material.Plastic] = { 0, 0 },
	[Enum.Material.SmoothPlastic] = { 0, 0 },
	[Enum.Material.Wood] = { 0, 0 },
	[Enum.Material.WoodPlanks] = { 0, 0 },
	-- Exemplo com MaterialVariant: defina Default + um som por variant.
	[Enum.Material.Concrete] = {
		Default = { 0, 0 },
		Variants = {
			["Concrete Tile (Studded)"] = {80035499887071, 136016935477404, 98834224741187, 133131975212473, 93940405519254, 107371415849519, 123925475829494 },
		},
	},
	[Enum.Material.Pavement] = { 
		Default = { 0, 0 },
		Variants = {
			["Base White TIle"] = {80035499887071, 136016935477404, 98834224741187, 133131975212473, 93940405519254, 107371415849519, 123925475829494 }, --- Its really "TIle"
		},
	},
	[Enum.Material.Asphalt] = { 0, 0 },
	[Enum.Material.Brick] = { 0, 0 },
	[Enum.Material.Cobblestone] = { 0, 0 },
	[Enum.Material.Marble] = { 0, 0 },
	[Enum.Material.Granite] = { 0, 0 },
	[Enum.Material.Slate] = { 0, 0 },
	[Enum.Material.Limestone] = { 0, 0 },
	[Enum.Material.Sandstone] = { 0, 0 },
	[Enum.Material.Basalt] = { 0, 0 },
	[Enum.Material.Rock] = { 0, 0 },
	[Enum.Material.Pebble] = { 0, 0 },
	[Enum.Material.CrackedLava] = { 0, 0 },

	-- Metais
	[Enum.Material.Metal] = { 0, 0 },
	[Enum.Material.CorrodedMetal] = { 0, 0 },
	[Enum.Material.DiamondPlate] = { 0, 0 },
	[Enum.Material.Foil] = { 0, 0 },

	-- Naturais / terreno
	[Enum.Material.Grass] = { 0, 0 },
	[Enum.Material.LeafyGrass] = { 0, 0 },
	[Enum.Material.Ground] = { 0, 0 },
	[Enum.Material.Mud] = { 0, 0 },
	[Enum.Material.Sand] = { 0, 0 },
	[Enum.Material.Salt] = { 0, 0 },
	[Enum.Material.Snow] = { 0, 0 },
	[Enum.Material.Ice] = { 0, 0 },
	[Enum.Material.Glacier] = { 0, 0 },

	-- Outros
	[Enum.Material.Fabric] = { 0, 0 },
	[Enum.Material.Glass] = { 0, 0 },
	[Enum.Material.Water] = { 0, 0 },
}

-- Superficies customizadas: chave (string) -> lista de variacoes. A chave vem do atributo
-- "CustomFootstep" da BasePart que o raycast colidir, e tem prioridade sobre o material/variant.
-- (0 = placeholder a ser substituido pelo id real)
FootstepSounds.Custom = {
	-- ["MetalGrate"] = { 0, 0 },
	["OfficePaper"] = { 112520752240063, 102832251556773, 111199342505980, 92981793649339, 109896892844498, 73691851220021, 128662976598802 },
} :: { [string]: { AssetId } }

-- Normaliza uma entrada (lista simples OU MaterialEntry) num par (listaDefault, variants).
local function unpackEntry(entry: any): ({ AssetId }, { [string]: { AssetId } }?)
	if entry == nil then
		return {}, nil
	end
	-- MaterialEntry e reconhecida por ter Default e/ou Variants; caso contrario e a propria lista.
	if entry.Default ~= nil or entry.Variants ~= nil then
		return entry.Default or {}, entry.Variants
	end
	return entry, nil
end

-- Retorna a lista de variacoes para um material (+ variant opcional), com fallback:
-- variant especifica -> Default do material -> DefaultMaterial.
function FootstepSounds.GetForMaterial(material: Enum.Material, variant: string?): { AssetId }
	local defaultList, variants = unpackEntry(FootstepSounds.Sounds[material])

	-- 1) MaterialVariant especifica.
	if variant and variant ~= "" and variants then
		local variantList = variants[variant]
		if variantList and #variantList > 0 then
			return variantList
		end
	end

	-- 2) Default do proprio material.
	if #defaultList > 0 then
		return defaultList
	end

	-- 3) Material de fallback (ignora variant).
	if material ~= FootstepSounds.DefaultMaterial then
		local fallbackList = unpackEntry(FootstepSounds.Sounds[FootstepSounds.DefaultMaterial])
		return fallbackList
	end

	return {}
end

-- Retorna todos os asset ids validos (> 0) do catalogo, sem repeticao (incluindo Defaults e todas
-- as Variants). Usado pelo controller para pre-carregar e cachear/normalizar os sons.
function FootstepSounds.GetAllIds(): { AssetId }
	local seen: { [AssetId]: boolean } = {}
	local ids: { AssetId } = {}

	local function add(list: { AssetId }?)
		if not list then
			return
		end
		for _, id in list do
			if id and id > 0 and not seen[id] then
				seen[id] = true
				table.insert(ids, id)
			end
		end
	end

	for _, entry in FootstepSounds.Sounds do
		local defaultList, variants = unpackEntry(entry)
		add(defaultList)
		if variants then
			for _, variantList in variants do
				add(variantList)
			end
		end
	end

	-- Superficies customizadas (carregadas junto com os materiais).
	for _, list in FootstepSounds.Custom do
		add(list)
	end

	return ids
end

-- Sorteia um asset id valido (> 0) de uma lista, evitando `exclude` (o ultimo som tocado) para nao
-- repetir dois passos seguidos. Se `exclude` for o unico id valido, permite repetir (senao nao
-- tocaria nada). Retorna nil se so houver placeholders (evita "Unable to load sound" com id 0).
local function pickRandomValid(list: { AssetId }, exclude: AssetId?): AssetId?
	local valid: { AssetId } = {}
	for _, id in list do
		if id and id > 0 and id ~= exclude then
			table.insert(valid, id)
		end
	end

	-- A exclusao esvaziou: havia apenas o ultimo id (uma unica variacao valida). Permite repetir.
	if #valid == 0 and exclude then
		for _, id in list do
			if id and id > 0 then
				table.insert(valid, id)
			end
		end
	end

	if #valid == 0 then
		return nil
	end
	return valid[math.random(#valid)]
end

-- Sorteia um asset id valido para o material/variant, evitando `exclude` (ultimo som tocado).
function FootstepSounds.GetRandomId(material: Enum.Material, variant: string?, exclude: AssetId?): AssetId?
	return pickRandomValid(FootstepSounds.GetForMaterial(material, variant), exclude)
end

-- Raycast curto para baixo a partir do personagem para inspecionar a peca do chao. Retorna:
--   custom  -> valor do atributo "CustomFootstep" da peca (string), se houver (tem prioridade);
--   variant -> MaterialVariant da peca (Humanoid.FloorMaterial so da o Enum.Material base), se houver.
-- Ambos podem ser nil. Usado pelo FootstepController (client) e pelo FootstepService (server).
function FootstepSounds.GetFloorInfo(character: Model, rootPart: BasePart): (string?, string?)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	params.IgnoreWater = true

	local result = workspace:Raycast(rootPart.Position, Vector3.new(0, -10, 0), params)
	if not result or not result.Instance then
		return nil, nil
	end

	local instance = result.Instance
	local custom: string? = nil
	local attr = instance:GetAttribute("CustomFootstep")
	if typeof(attr) == "string" and attr ~= "" then
		custom = attr
	end

	local variant: string? = nil
	if instance.MaterialVariant ~= "" then
		variant = instance.MaterialVariant
	end

	return custom, variant
end

-- Sorteia um asset id valido para uma superficie customizada (chave do atributo "CustomFootstep"),
-- evitando `exclude` (ultimo som tocado). Retorna nil se a chave nao existir ou so tiver placeholders.
function FootstepSounds.GetRandomCustomId(key: string, exclude: AssetId?): AssetId?
	local list = FootstepSounds.Custom[key]
	if not list then
		return nil
	end
	return pickRandomValid(list, exclude)
end

return FootstepSounds
