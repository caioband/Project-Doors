--!strict
-- FlashlightService
-- Responsavel por:
--   * Garantir os Remotes em ReplicatedStorage.Comms.Flashlight (Equip / Unequip)
--   * Ao equipar: clonar ReplicatedStorage.Assets.Models.Items.Flashlight, soldar na mao
--     direita do character e ligar o SpotLight. Como roda no servidor, o modelo replica
--     para TODOS os clientes (o dono destroi a copia local para nao atrapalhar a 1a pessoa).
--   * Ao desequipar (ou sair / morrer): destruir o modelo.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local FlashlightService = {}

-- Nome dado ao modelo equipado dentro do character (o cliente do dono usa para destrui-lo).
local EQUIPPED_NAME = "EquippedFlashlight"

-- Encaixe do flashlight relativo a mao (C0 do Weld). Ajuste fino do "grip" aqui.
local GRIP_C0 = CFrame.new(0, -0.4, -0.4) * CFrame.Angles(math.rad(180), 0, 0)

-- Modelo equipado por jogador, para limpeza em desequip / saida / morte.
local equipped: { [Player]: BasePart } = {}

local EquipRemote: RemoteEvent
local UnequipRemote: RemoteEvent


-- Garante a hierarquia ReplicatedStorage.Comms.Flashlight e os RemoteEvents necessarios.
local function EnsureRemotes()
    local comms = ReplicatedStorage:FindFirstChild("Comms")
    if not comms then
        comms = Instance.new("Folder")
        comms.Name = "Comms"
        comms.Parent = ReplicatedStorage
    end

    local folder = comms:FindFirstChild("Flashlight")
    if not folder then
        folder = Instance.new("Folder")
        folder.Name = "Flashlight"
        folder.Parent = comms
    end

    EquipRemote = folder:FindFirstChild("Equip") :: RemoteEvent
    if not EquipRemote then
        EquipRemote = Instance.new("RemoteEvent")
        EquipRemote.Name = "Equip"
        EquipRemote.Parent = folder
    end

    UnequipRemote = folder:FindFirstChild("Unequip") :: RemoteEvent
    if not UnequipRemote then
        UnequipRemote = Instance.new("RemoteEvent")
        UnequipRemote.Name = "Unequip"
        UnequipRemote.Parent = folder
    end
end


-- Acha a parte da mao direita, suportando rig R15 (RightHand) e R6 (Right Arm).
local function FindRightHand(character: Model): BasePart?
    local hand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
    return hand :: BasePart?
end


-- Destroi o flashlight equipado de um jogador, se houver.
local function DestroyFlashlight(player: Player)
    local part = equipped[player]
    equipped[player] = nil
    if part then
        part:Destroy()
    end
end


-- Clona o template, solda na mao direita do character e liga o SpotLight.
local function OnEquip(player: Player)
    local character = player.Character
    if not character then
        return
    end

    local hand = FindRightHand(character)
    if not hand then
        warn("FlashlightService: mao direita nao encontrada no character de " .. player.Name)
        return
    end

    -- Evita duplicar caso ja exista um equipado.
    DestroyFlashlight(player)

    local template = ReplicatedStorage.Assets.Models.Items.Flashlight
    local part = template:Clone() :: BasePart
    part.Name = EQUIPPED_NAME
    part.Anchored = false
    part.CanCollide = false
    part.CanQuery = false
    part.Massless = true
    part:SetAttribute("Owner", player.UserId)

    -- Liga o SpotLight do modelo.
    local spotlight = part:FindFirstChildWhichIsA("SpotLight")
    if spotlight then
        spotlight.Enabled = true
    end

    -- Posiciona e solda na mao (o C0 define o encaixe relativo a mao).
    part.CFrame = hand.CFrame * GRIP_C0
    local weld = Instance.new("Weld")
    weld.Name = "FlashlightWeld"
    weld.Part0 = hand
    weld.Part1 = part
    weld.C0 = GRIP_C0
    weld.Parent = part

    part.Parent = character
    equipped[player] = part
end


function FlashlightService:Init()
    EnsureRemotes()
end


function FlashlightService:Start()
    EquipRemote.OnServerEvent:Connect(OnEquip)
    UnequipRemote.OnServerEvent:Connect(DestroyFlashlight)

    Players.PlayerAdded:Connect(function(player)
        player.CharacterRemoving:Connect(function()
            DestroyFlashlight(player)
        end)
    end)

    Players.PlayerRemoving:Connect(DestroyFlashlight)
end


return FlashlightService
