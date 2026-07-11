--!strict
-- RespawnService (server)
-- Complementa o DownedService com o sistema de VIDAS + respawn manual + voltar ao menu.
--
-- Como CharacterAutoLoads esta desativado (spawn manual em init.server.lua), quando o player morre
-- (State -> "Dead", setado pelo DownedService) o personagem NAO reaparece sozinho: ele fica morto
-- (vendo a DeathScreen) ate acionar o botao Respawn, que pede um novo LoadCharacter ao server.
--
-- Vidas: cada player recebe STARTING_LIVES ao entrar (atributo "Lives" no Player, replica para o
-- client). Cada morte real desconta 1; ao chegar a zero o player nao pode mais respawnar (o client
-- esconde o botao Respawn e so resta BackToMenu).
--
-- Comunicacao via ReplicatedStorage.Comms.Death: RemoteEvents "Respawn" e "BackToMenu" (client -> server).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local ServerShared = ServerScriptService:WaitForChild("Server"):WaitForChild("SharedModules")
local SafeTeleport = require(ServerShared:WaitForChild("SafeTeleport"))

-- Vidas que cada player recebe ao entrar. Cada morte (State -> "Dead") desconta 1.
local STARTING_LIVES = 3

-- PlaceId do Menu para onde o botao BackToMenu teleporta.
-- TODO: preencher com o PlaceId real do Menu (enquanto for <= 0, o BackToMenu apenas loga um aviso).
local MENU_PLACE_ID = 0

local RespawnRemote: RemoteEvent
local BackToMenuRemote: RemoteEvent

local RespawnService = {}

-- Garante ReplicatedStorage.Comms.Death e os RemoteEvents Respawn / BackToMenu.
local function ensureRemotes()
	local comms = ReplicatedStorage:FindFirstChild("Comms")
	if not comms then
		comms = Instance.new("Folder")
		comms.Name = "Comms"
		comms.Parent = ReplicatedStorage
	end

	local deathFolder = comms:FindFirstChild("Death")
	if not deathFolder then
		deathFolder = Instance.new("Folder")
		deathFolder.Name = "Death"
		deathFolder.Parent = comms
	end

	RespawnRemote = deathFolder:FindFirstChild("Respawn") :: RemoteEvent
	if not RespawnRemote then
		RespawnRemote = Instance.new("RemoteEvent")
		RespawnRemote.Name = "Respawn"
		RespawnRemote.Parent = deathFolder
	end

	BackToMenuRemote = deathFolder:FindFirstChild("BackToMenu") :: RemoteEvent
	if not BackToMenuRemote then
		BackToMenuRemote = Instance.new("RemoteEvent")
		BackToMenuRemote.Name = "BackToMenu"
		BackToMenuRemote.Parent = deathFolder
	end
end

-- Vidas atuais do player (0 se o atributo ainda nao foi setado).
function RespawnService:GetLives(player: Player): number
	local lives = player:GetAttribute("Lives")
	return if typeof(lives) == "number" then lives else 0
end

-- Respawn manual: recarrega o personagem se ainda houver vidas e o player estiver de fato morto
-- (evita recarregar um personagem vivo por spam do botao). O DownedService reinicializa o novo
-- personagem em Alive com vida cheia.
function RespawnService:RequestRespawn(player: Player)
	if self:GetLives(player) <= 0 then
		return
	end

	local character = player.Character
	if character and character:GetAttribute("State") ~= "Dead" then
		return
	end

	player:LoadCharacter()
end

-- Teleporta o player de volta ao Menu (se o PlaceId estiver configurado).
function RespawnService:RequestBackToMenu(player: Player)
	if MENU_PLACE_ID <= 0 then
		warn("[RespawnService] MENU_PLACE_ID nao configurado; BackToMenu ignorado.")
		return
	end
	SafeTeleport:Teleport(MENU_PLACE_ID, { player })
end

function RespawnService:Init()
	ensureRemotes()
end

function RespawnService:Start()
	-- Desconta uma vida na PRIMEIRA vez que ESTE personagem entrar em "Dead" (o guard evita
	-- descontos duplicados caso o atributo State dispare mais de uma vez).
	local function onCharacterAdded(player: Player, character: Model)
		local counted = false
		character:GetAttributeChangedSignal("State"):Connect(function()
			if counted then
				return
			end
			if character:GetAttribute("State") == "Dead" then
				counted = true
				local lives = math.max(0, self:GetLives(player) - 1)
				player:SetAttribute("Lives", lives)
			end
		end)
	end

	local function onPlayerAdded(player: Player)
		player:SetAttribute("Lives", STARTING_LIVES)
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

	RespawnRemote.OnServerEvent:Connect(function(player)
		self:RequestRespawn(player)
	end)
	BackToMenuRemote.OnServerEvent:Connect(function(player)
		self:RequestBackToMenu(player)
	end)

	print("✓ RespawnService initialized")
end

return RespawnService
