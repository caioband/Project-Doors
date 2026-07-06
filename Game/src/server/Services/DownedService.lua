--!strict
-- DownedService (server)
-- Sistema autoritativo de vida custom + estado de "downed" (agonizante) + morte.
--
-- Fonte da verdade sao ATRIBUTOS no Character (replicam para todos os clientes):
--   * Health (number) : vida custom. O Humanoid.Health padrao fica cheio; so zeramos ele no
--                        momento de matar de fato (mantem o respawn padrao do Roblox funcionando).
--   * State (string)  : "Alive" | "Downed" | "Dead".
--   * DownedToken (n) : geracao usada para invalidar o timer de morte quando o player e revivido.
--
-- Fluxo:
--   Alive --ApplyDamage-> Health<=0 --> (sozinho no server? Kill : Downed)
--   Downed --ProximityPrompt de revive acionado por OUTRO player--> Alive (Health = MAX)
--   Downed --DOWNED_DURATION s sem revive--> Kill
--   Dead --> respawn padrao (CharacterAdded) --> Alive
--
-- Nao usa RemoteEvents: os clientes reagem ao atributo State; o revive e 100% server (via
-- ProximityPromptService.PromptTriggered); o spectate e resolvido no client lendo Players.

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")

local DownedService = {}

-- Vida maxima inicial do personagem.
local MAX_HEALTH = 100
-- Tempo (s) que o player fica em Downed antes de morrer se ninguem reviver.
local DOWNED_DURATION = 30
-- Tempo (s) que o outro player precisa segurar o prompt para reviver.
local REVIVE_HOLD = 3
-- Distancia (studs) de ativacao do prompt de revive.
local REVIVE_DISTANCE = 8
-- Nome do ProximityPrompt criado no personagem downed.
local REVIVE_PROMPT_NAME = "RevivePrompt"

-- Resolve o Character valido de um player (com Humanoid e HumanoidRootPart), ou nil.
local function getCharacter(player: Player): Model?
	local character = player.Character
	if not character or not character.Parent then
		return nil
	end
	return character
end

local function getHumanoid(character: Model): Humanoid?
	return character:FindFirstChildOfClass("Humanoid")
end

-- Inicializa (ou reinicializa) o personagem no estado Alive com vida cheia.
local function initCharacter(character: Model)
	character:SetAttribute("Health", MAX_HEALTH)
	character:SetAttribute("State", "Alive")
	character:SetAttribute("DownedToken", 0)
end

-- Remove o prompt de revive do personagem, se existir.
local function destroyRevivePrompt(character: Model)
	local root = character.PrimaryPart or character:FindFirstChild("HumanoidRootPart")
	local prompt = root and root:FindFirstChild(REVIVE_PROMPT_NAME)
	if prompt then
		prompt:Destroy()
	end
end


-- Aplica dano ao player: apenas DESCONTA o atributo Health (guardado >= 0). Ignora se o player
-- nao estiver Alive (nao se leva dano ja caido/morto). A transicao para Downed/Kill NAO acontece
-- aqui: e disparada pelo listener do atributo Health (:_handleHealthChanged), para valer tambem
-- quando o Health e alterado por qualquer outra fonte (ex.: setar o atributo direto).
function DownedService:ApplyDamage(player: Player, amount: number)
	local character = getCharacter(player)
	if not character then
		return
	end
	if character:GetAttribute("State") ~= "Alive" then
		return
	end

	local current = character:GetAttribute("Health")
	if typeof(current) ~= "number" then
		current = MAX_HEALTH
	end

	character:SetAttribute("Health", math.max(0, current - amount))
end


-- Reage a mudancas no atributo Health (de qualquer fonte). Quando a vida chega a zero e o player
-- ainda esta Alive: morre na hora se estiver sozinho no server, senao entra em Downed.
function DownedService:_handleHealthChanged(player: Player)
	local character = getCharacter(player)
	if not character then
		return
	end
	if character:GetAttribute("State") ~= "Alive" then
		return
	end

	local hp = character:GetAttribute("Health")
	if typeof(hp) ~= "number" or hp > 0 then
		return
	end

	if #Players:GetPlayers() <= 1 then
		self:Kill(player)
	else
		self:Downed(player)
	end
end


-- Coloca o player no estado Downed: cria o prompt de revive e agenda a morte por timeout.
function DownedService:Downed(player: Player)
	local character = getCharacter(player)
	if not character then
		return
	end

	character:SetAttribute("State", "Downed")

	-- Geracao nova: invalida qualquer timer de downed anterior.
	local token = (character:GetAttribute("DownedToken") or 0) + 1
	character:SetAttribute("DownedToken", token)

	local root = character.PrimaryPart or character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") and not root:FindFirstChild(REVIVE_PROMPT_NAME) then
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = REVIVE_PROMPT_NAME
		prompt.ObjectText = "Revive"
		prompt.ActionText = "Segurar"
		prompt.HoldDuration = REVIVE_HOLD
		prompt.MaxActivationDistance = REVIVE_DISTANCE
		prompt.RequiresLineOfSight = false
		prompt:SetAttribute("RevivePrompt", true)
		-- O proprio player downed esconde este prompt localmente no client (write client-only).
		prompt.Parent = root
	end

	-- Morte por timeout: se apos DOWNED_DURATION ainda estiver Downed com o mesmo token, morre.
	task.delay(DOWNED_DURATION, function()
		local char = getCharacter(player)
		if not char then
			return
		end
		if char:GetAttribute("State") == "Downed" and char:GetAttribute("DownedToken") == token then
			self:Kill(player)
		end
	end)
end


-- Revive o player: volta para Alive com vida cheia, invalida o timer e remove o prompt.
function DownedService:Revive(player: Player)
	local character = getCharacter(player)
	if not character then
		return
	end
	if character:GetAttribute("State") ~= "Downed" then
		return
	end

	-- Invalida o timer de morte pendente.
	character:SetAttribute("DownedToken", (character:GetAttribute("DownedToken") or 0) + 1)
	character:SetAttribute("Health", MAX_HEALTH)
	character:SetAttribute("State", "Alive")
	destroyRevivePrompt(character)
end


-- Mata o player de fato: marca Dead, remove o prompt e zera o Humanoid.Health (respawn padrao).
function DownedService:Kill(player: Player)
	local character = getCharacter(player)
	if not character then
		return
	end

	character:SetAttribute("State", "Dead")
	character:SetAttribute("Health", 0)
	destroyRevivePrompt(character)

	local humanoid = getHumanoid(character)
	if humanoid then
		humanoid.Health = 0
	end
end


function DownedService:Init()
	-- Sem remotes: o estado replica via atributos do Character.
end


function DownedService:Start()
	local function onCharacterAdded(player: Player, character: Model)
		-- Espera o Humanoid para garantir que o personagem esta montado antes de inicializar.
		character:WaitForChild("Humanoid", 10)
		initCharacter(character)

		-- Escuta o proprio atributo Health: quando chega a zero, dispara a transicao (Downed/Kill).
		-- Conectado APOS o initCharacter para o set inicial (Health = MAX) nao disparar nada.
		character:GetAttributeChangedSignal("Health"):Connect(function()
			self:_handleHealthChanged(player)
		end)
	end

	local function onPlayerAdded(player: Player)
		player.CharacterAdded:Connect(function(character)
			onCharacterAdded(player, character)
		end)
		if player.Character then
			onCharacterAdded(player, player.Character)
		end
	end

	for _, player in ipairs(Players:GetPlayers()) do
		onPlayerAdded(player)
	end
	Players.PlayerAdded:Connect(onPlayerAdded)

	-- Revive via prompt: so revive se quem acionou for OUTRO player e o dono ainda estiver Downed.
	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, triggerPlayer: Player)
		if not prompt:GetAttribute("RevivePrompt") then
			return
		end

		local ownerCharacter = prompt:FindFirstAncestorOfClass("Model")
		local ownerPlayer = ownerCharacter and Players:GetPlayerFromCharacter(ownerCharacter)
		if not ownerPlayer or ownerPlayer == triggerPlayer then
			return
		end

		self:Revive(ownerPlayer)
	end)

	print("✓ DownedService initialized")
end


return DownedService
