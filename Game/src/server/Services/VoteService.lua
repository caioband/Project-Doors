--!strict
-- VoteService
-- Responsavel por:
--   * Garantir a existencia dos Remotes em ReplicatedStorage.Comms.Votation (cria caso nao existam)
--   * Iniciar a votacao quando um jogador aciona o botao (ButtonCalled) e devolver o status atual
--   * Registrar os votos vindos do cliente (Vote) e transmitir cada escolha para todos os
--     jogadores (BroadcastVote), para que todos vejam a porta escolhida

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local VoteService = {}

-- Quantidade de portas disponiveis na sala de votacao. Usado para validar o indice recebido.
local DOOR_COUNT = 2

-- Estado da votacao em andamento.
local VotingActive = false
-- Votos atuais por jogador: [player] = indice da porta.
local Votes: { [Player]: number } = {}
-- Ultima escolha registrada (porta), enviada a quem entra na votacao ja iniciada.
local LatestChoice: number? = nil

local ButtonCalledRemote: RemoteFunction
local VoteRemote: RemoteFunction
local BroadcastVoteRemote: RemoteEvent
local VotingStartedRemote: RemoteEvent
local VotingResetRemote: RemoteEvent


-- Contabiliza os votos por porta: retorna um array de tamanho DOOR_COUNT em que cada
-- posicao tem o numero de votos daquela porta (apenas votos, nao numero de jogadores).
local function ComputeCounts(): { number }
    local counts: { number } = table.create(DOOR_COUNT, 0)
    for _, doorIndex in pairs(Votes) do
        if doorIndex >= 1 and doorIndex <= DOOR_COUNT then
            counts[doorIndex] += 1
        end
    end
    return counts
end


-- Garante a hierarquia ReplicatedStorage.Comms.Votation e os Remotes necessarios.
local function EnsureRemotes()
    local comms = ReplicatedStorage:FindFirstChild("Comms")
    if not comms then
        comms = Instance.new("Folder")
        comms.Name = "Comms"
        comms.Parent = ReplicatedStorage
    end

    local votationFolder = comms:FindFirstChild("Votation")
    if not votationFolder then
        votationFolder = Instance.new("Folder")
        votationFolder.Name = "Votation"
        votationFolder.Parent = comms
    end

    ButtonCalledRemote = votationFolder:FindFirstChild("ButtonCalled") :: RemoteFunction
    if not ButtonCalledRemote then
        ButtonCalledRemote = Instance.new("RemoteFunction")
        ButtonCalledRemote.Name = "ButtonCalled"
        ButtonCalledRemote.Parent = votationFolder
    end

    VoteRemote = votationFolder:FindFirstChild("Vote") :: RemoteFunction
    if not VoteRemote then
        VoteRemote = Instance.new("RemoteFunction")
        VoteRemote.Name = "Vote"
        VoteRemote.Parent = votationFolder
    end

    BroadcastVoteRemote = votationFolder:FindFirstChild("BroadcastVote") :: RemoteEvent
    if not BroadcastVoteRemote then
        BroadcastVoteRemote = Instance.new("RemoteEvent")
        BroadcastVoteRemote.Name = "BroadcastVote"
        BroadcastVoteRemote.Parent = votationFolder
    end

    VotingStartedRemote = votationFolder:FindFirstChild("VotingStarted") :: RemoteEvent
    if not VotingStartedRemote then
        VotingStartedRemote = Instance.new("RemoteEvent")
        VotingStartedRemote.Name = "VotingStarted"
        VotingStartedRemote.Parent = votationFolder
    end

    VotingResetRemote = votationFolder:FindFirstChild("VotingReset") :: RemoteEvent
    if not VotingResetRemote then
        VotingResetRemote = Instance.new("RemoteEvent")
        VotingResetRemote.Name = "VotingReset"
        VotingResetRemote.Parent = votationFolder
    end
end


-- Handler de ButtonCalled: se a votacao ainda nao iniciou, inicia (zerando os votos).
-- Sempre devolve o status para o cliente entrar no modo de votacao, junto da ultima escolha
-- (para quem entra com a votacao ja em andamento ver a porta atualmente selecionada).
local function OnButtonCalled(_player: Player): { status: string, latestChoice: number?, counts: { number } }
    if not VotingActive then
        VotingActive = true
        Votes = {}
        LatestChoice = nil
        -- Primeiro player da rodada a iniciar a votacao: avisa todos os clientes (libera os
        -- billboards de contagem) com a contagem zerada.
        VotingStartedRemote:FireAllClients(ComputeCounts())
    end

    return { status = "voting", latestChoice = LatestChoice, counts = ComputeCounts() }
end


-- Handler de Vote: valida e registra o voto (um por jogador), depois transmite a escolha
-- e a contagem atualizada de votos por porta para todos os clientes.
local function OnVote(player: Player, doorIndex: any): { success: boolean }
    if not VotingActive then
        return { success = false }
    end

    if typeof(doorIndex) ~= "number" or doorIndex ~= math.floor(doorIndex) then
        return { success = false }
    end

    if doorIndex < 1 or doorIndex > DOOR_COUNT then
        return { success = false }
    end

    -- Um voto por jogador: ignora se ja votou.
    if Votes[player] then
        return { success = false }
    end

    Votes[player] = doorIndex
    LatestChoice = doorIndex

    -- Transmite a escolha e a contagem por porta para todos os jogadores (inclusive quem votou).
    BroadcastVoteRemote:FireAllClients(doorIndex, ComputeCounts())

    return { success = true }
end


-- Reseta a votacao da rodada: zera votos/estado e avisa todos os clientes (escondem os
-- billboards, zeram a contagem e reabilitam o ProximityPrompt). Chame ao iniciar uma nova
-- rodada para que a votacao precise ser iniciada novamente pelo primeiro player.
function VoteService:ResetVotation()
    VotingActive = false
    Votes = {}
    LatestChoice = nil
    VotingResetRemote:FireAllClients()
end


function VoteService:Init()
    EnsureRemotes()
end


function VoteService:Start()
    ButtonCalledRemote.OnServerInvoke = OnButtonCalled
    VoteRemote.OnServerInvoke = OnVote

    Players.PlayerRemoving:Connect(function(player)
        Votes[player] = nil
    end)

    -- Sincroniza a contagem atual com quem entra, para os billboards das portas ja
    -- aparecerem com os votos corretos (sem porta especifica: doorIndex = nil).
    Players.PlayerAdded:Connect(function(player)
        BroadcastVoteRemote:FireClient(player, nil, ComputeCounts())
    end)
end


return VoteService
