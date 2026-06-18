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

-- Duracao (s) da votacao. O servidor conduz a contagem e conclui quando chega a zero.
local VOTE_DURATION = 20

-- Estado da votacao em andamento.
local VotingActive = false
-- Votos atuais por jogador: [player] = indice da porta.
local Votes: { [Player]: number } = {}
-- Ultima escolha registrada (porta), enviada a quem entra na votacao ja iniciada.
local LatestChoice: number? = nil

-- Instante (os.clock) em que a votacao termina; nil quando nao ha votacao ativa.
local VoteEndsAt: number? = nil
-- Geracao do timer: incrementada para invalidar/parar o loop de contagem anterior.
local TimerGeneration = 0

local ButtonCalledRemote: RemoteFunction
local VoteRemote: RemoteFunction
local BroadcastVoteRemote: RemoteEvent
local VotingStartedRemote: RemoteEvent
local VotingResetRemote: RemoteEvent
local VotingTimerRemote: RemoteEvent


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

    VotingTimerRemote = votationFolder:FindFirstChild("VotingTimer") :: RemoteEvent
    if not VotingTimerRemote then
        VotingTimerRemote = Instance.new("RemoteEvent")
        VotingTimerRemote.Name = "VotingTimer"
        VotingTimerRemote.Parent = votationFolder
    end
end


-- Segundos restantes da votacao (0 se nao houver votacao ativa).
local function RemainingSeconds(): number
    if not VoteEndsAt then
        return 0
    end
    return math.max(0, VoteEndsAt - os.clock())
end


-- Inicia a contagem regressiva no servidor: transmite os segundos restantes a cada segundo
-- e conclui a votacao automaticamente quando chega a zero.
local function StartTimer()
    TimerGeneration += 1
    local generation = TimerGeneration
    VoteEndsAt = os.clock() + VOTE_DURATION

    task.spawn(function()
        while generation == TimerGeneration and VotingActive do
            local remaining = math.ceil(RemainingSeconds())
            VotingTimerRemote:FireAllClients(remaining)
            if remaining <= 0 then
                break
            end
            task.wait(1)
        end

        -- Tempo esgotado (e ninguem reiniciou/resetou): conclui a votacao.
        if generation == TimerGeneration and VotingActive then
            VoteService:ConcludeVoting()
        end
    end)
end


-- Handler de ButtonCalled: se a votacao ainda nao iniciou, inicia (zerando os votos).
-- Sempre devolve o status para o cliente entrar no modo de votacao, junto da ultima escolha
-- (para quem entra com a votacao ja em andamento ver a porta atualmente selecionada).
local function OnButtonCalled(_player: Player): { status: string, latestChoice: number?, counts: { number }, remaining: number }
    if not VotingActive then
        VotingActive = true
        Votes = {}
        LatestChoice = nil
        -- Primeiro player da rodada a iniciar a votacao: inicia a contagem regressiva e avisa
        -- todos os clientes (libera os billboards de contagem) com a contagem zerada.
        StartTimer()
        VotingStartedRemote:FireAllClients(ComputeCounts())
    end

    return {
        status = "voting",
        latestChoice = LatestChoice,
        counts = ComputeCounts(),
        remaining = math.ceil(RemainingSeconds()),
    }
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


-- Indica se a votacao da rodada esta em andamento (usado pelo RoundService para saber
-- quando a janela de votacao comecou/terminou).
function VoteService:IsVotingActive(): boolean
    return VotingActive
end


-- Segundos restantes da votacao (0 se nao houver votacao ativa). Exposto para consumo externo.
function VoteService:GetRemaining(): number
    return math.ceil(RemainingSeconds())
end


-- Conclui a votacao (tempo esgotado): para a contagem e impede novos votos. Mantem os votos
-- registrados para apuracao (TallyWinner); o RoundService chama ResetVotation depois.
function VoteService:ConcludeVoting()
    if not VotingActive then
        return
    end
    VotingActive = false
    TimerGeneration += 1
    VoteEndsAt = nil
    -- Tick final em zero para os clientes fecharem o cronometro/saida do modo de votacao.
    VotingTimerRemote:FireAllClients(0)
end


-- Apura o vencedor da votacao: retorna o indice da porta mais votada. Empate e resolvido
-- pela porta de menor indice; sem votos, retorna 1. Usado pelo RoundService para escolher o mapa.
function VoteService:TallyWinner(): number
    local counts = ComputeCounts()
    local winner = 1
    local best = -1
    for doorIndex = 1, DOOR_COUNT do
        if counts[doorIndex] > best then
            best = counts[doorIndex]
            winner = doorIndex
        end
    end
    return winner
end


-- Reseta a votacao da rodada: zera votos/estado e avisa todos os clientes (escondem os
-- billboards, zeram a contagem e reabilitam o ProximityPrompt). Chame ao iniciar uma nova
-- rodada para que a votacao precise ser iniciada novamente pelo primeiro player.
function VoteService:ResetVotation()
    VotingActive = false
    -- Para qualquer contagem em andamento.
    TimerGeneration += 1
    VoteEndsAt = nil
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
        -- Sincroniza o cronometro para quem entra com a votacao ja em andamento.
        if VotingActive then
            VotingTimerRemote:FireClient(player, math.ceil(RemainingSeconds()))
        end
    end)
end


return VoteService
