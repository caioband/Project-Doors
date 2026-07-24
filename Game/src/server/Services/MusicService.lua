--!strict
-- MusicService
-- Controla o radio da sala de votacao (Workspace.MapInUse.VotingRoom.ClassicRadio.MusicPlayer):
--   * Toca as musicas de uma playlist (PLAYLIST), seguindo a ordem do array
--   * Comeca a tocar a primeira musica assim que o servidor inicializa (Start)
--   * O ProximityPrompt faz um toggle de mutar/desmutar o audio (o ActionText do prompt vira
--     "Mute" enquanto tem som e "Unmute" enquanto mutado). A musica continua tocando mutada.
--   * Quando uma musica termina naturalmente, avanca sozinho para a proxima (playlist continua);
--     ao passar do fim do array, volta para o comeco (wrap-around)
--
-- Mutar apenas zera o AudioPlayer.Volume (guardando o volume anterior para restaurar); a
-- reproducao segue rodando por baixo, so sem som.
--
-- O roteamento de audio (AudioPlayer -> Wire -> AudioEmitter) ja esta montado na cena; este
-- Service so define o AudioPlayer.Asset e chama :Play(). Preencha PLAYLIST com os ids das musicas.

local Workspace = game:GetService("Workspace")

local MusicService = {}

-- Playlist do radio. A ORDEM do array e a ordem de reproducao. Aceita ids como numero
-- (12345678) ou como string ("rbxassetid://12345678"). Vazio = nao toca nada.
-- TODO: preencher com os ids das musicas.
local PLAYLIST: { string | number } = {
	72551344238561, 
	104442722751005,
	83956700298147,
	113432440036067,
	73756211026166,
	86498395265218,
	104166662679135
	-- 0000000000,
	-- 0000000001,
}

-- Tempo (s) que esperamos os objetos do radio existirem antes de desistir (evita travar caso a
-- VotingRoom nao esteja carregada).
local RESOLVE_TIMEOUT = 15

-- Tempo maximo (s) que esperamos o asset da musica carregar (IsReady/TimeLength) antes de tocar
-- mesmo assim. Sem carregar a tempo, a regiao fica no padrao do objeto (nao trava a reproducao).
local LOAD_TIMEOUT = 10

-- Indice da musica atual dentro de PLAYLIST.
local currentIndex = 1

-- Token de reproducao: incrementado a cada troca de musica para invalidar uma reproducao que ainda
-- estava esperando o asset carregar (evita "voltar" para uma faixa antiga se o player trocar rapido).
local playToken = 0

-- Estado de mute do radio, controlado pelo toggle do ProximityPrompt.
local isMuted = false
-- Volume a restaurar ao desmutar (capturado do AudioPlayer ao mutar). Inicializado no Start.
local unmutedVolume = 1

local audioPlayer: AudioPlayer? = nil
local proximityPrompt: ProximityPrompt? = nil

-- Converte um id (numero ou string) para a URI aceita pelo AudioPlayer.Asset.
local function ToAssetUri(id: string | number): string
	if typeof(id) == "number" then
		return "rbxassetid://" .. tostring(id)
	end
	return id
end

-- Atualiza o texto do prompt conforme o estado: "Mute" com som, "Unmute" mutado.
local function UpdatePromptText()
	if proximityPrompt then
		proximityPrompt.ActionText = isMuted and "Unmute" or "Mute"
	end
end

-- Espera o asset carregar (IsReady vira true e TimeLength passa a valer > 0), com teto de tempo.
local function WaitUntilReady(player: AudioPlayer)
	local deadline = os.clock() + LOAD_TIMEOUT
	while not player.IsReady and os.clock() < deadline do
		task.wait(0.1)
	end
end

-- Toca a musica do indice atual. Sem playlist (ou sem AudioPlayer resolvido), nao faz nada.
-- Ao trocar de faixa, espera ela carregar e ajusta PlaybackRegion/LoopRegion para a duracao real
-- da musica (NumberRange em milissegundos), evitando o corte no padrao de 60s do objeto.
local function PlayCurrent()
	if #PLAYLIST == 0 or not audioPlayer then
		return
	end

	-- Mantem o indice dentro dos limites (wrap-around defensivo).
	if currentIndex < 1 or currentIndex > #PLAYLIST then
		currentIndex = 1
	end

	local player = audioPlayer :: AudioPlayer

	playToken += 1
	local token = playToken

	player:Stop()
	player.Asset = ToAssetUri(PLAYLIST[currentIndex])

	-- Espera o asset carregar para conhecer a duracao antes de definir a regiao e tocar.
	WaitUntilReady(player)

	-- Se o player ja trocou de musica enquanto esta carregava, aborta esta reproducao.
	if token ~= playToken then
		return
	end

	-- Regiao = musica inteira. TimeLength esta em segundos; a regiao e NumberRange em milissegundos.
	local lengthMs = player.TimeLength * 1000
	if lengthMs > 0 then
		player.PlaybackRegion = NumberRange.new(0, lengthMs)
		player.LoopRegion = NumberRange.new(0, lengthMs)
	end

	-- O mute e uma preferencia do radio: mantem entre faixas. Garante que o volume da nova faixa
	-- respeite o estado atual (0 se mutado, o volume salvo caso contrario) antes de tocar.
	player.Volume = isMuted and 0 or unmutedVolume

	player:Play()
end

-- Avanca para a proxima musica do array; ao passar do fim, volta para o comeco. Depois toca.
local function PlayNext()
	if #PLAYLIST == 0 then
		return
	end

	currentIndex += 1
	if currentIndex > #PLAYLIST then
		currentIndex = 1
	end

	PlayCurrent()
end

-- Toggle acionado pelo prompt: muta (zera o volume, guardando o atual) ou desmuta (restaura o
-- volume salvo). A musica continua tocando por baixo. Sem AudioPlayer, nao faz nada.
local function ToggleMute()
	if not audioPlayer then
		return
	end

	local player = audioPlayer :: AudioPlayer

	if isMuted then
		-- Desmutar: restaura o volume que estava antes de mutar.
		player.Volume = unmutedVolume
		isMuted = false
	else
		-- Mutar: guarda o volume atual (caso tenha sido ajustado) e zera.
		if player.Volume > 0 then
			unmutedVolume = player.Volume
		end
		player.Volume = 0
		isMuted = true
	end

	UpdatePromptText()
end

-- Resolve os objetos do radio na VotingRoom persistente (Workspace.MapInUse.VotingRoom).
-- Retorna false (com aviso) se algo nao for encontrado no tempo limite.
local function ResolveInstances(): boolean
	local mapInUse = Workspace:WaitForChild("MapInUse", RESOLVE_TIMEOUT)
	local votingRoom = mapInUse and mapInUse:WaitForChild("VotingRoom", RESOLVE_TIMEOUT)
	local classicRadio = votingRoom and votingRoom:WaitForChild("ClassicRadio", RESOLVE_TIMEOUT)
	local musicPlayer = classicRadio and classicRadio:WaitForChild("MusicPlayer", RESOLVE_TIMEOUT)

	if not musicPlayer then
		warn("[MusicService] MusicPlayer nao encontrado em Workspace.MapInUse.VotingRoom.ClassicRadio.")
		return false
	end

	audioPlayer = musicPlayer:WaitForChild("AudioPlayer", RESOLVE_TIMEOUT) :: AudioPlayer
	proximityPrompt = musicPlayer:WaitForChild("ProximityPrompt", RESOLVE_TIMEOUT) :: ProximityPrompt

	if not audioPlayer or not proximityPrompt then
		warn("[MusicService] AudioPlayer/ProximityPrompt do radio nao encontrados.")
		return false
	end

	return true
end


function MusicService:Init()
	ResolveInstances()
end


function MusicService:Start()
	-- Se os objetos nao foram resolvidos no Init, nao ha o que conectar.
	if not audioPlayer or not proximityPrompt then
		return
	end

	local player = audioPlayer :: AudioPlayer
	local prompt = proximityPrompt :: ProximityPrompt

	-- Nao queremos loop da faixa: quando ela termina, avancamos para a proxima (playlist continua).
	player.Looping = false

	-- Volume base do radio (o configurado no objeto) usado ao desmutar. Comeca com som e o texto
	-- do prompt refletindo isso ("Mute").
	unmutedVolume = if player.Volume > 0 then player.Volume else 1
	isMuted = false
	UpdatePromptText()

	-- Cada acionamento do prompt muta/desmuta o audio (toggle).
	prompt.Triggered:Connect(function()
		ToggleMute()
	end)

	-- Musica terminou sozinha -> proxima faixa, mantendo o radio sempre tocando.
	player.Ended:Connect(function()
		PlayNext()
	end)

	-- Comeca tocando a primeira musica assim que o servidor sobe. Em thread separada porque
	-- PlayCurrent espera o asset carregar (yield) e o Start nao deve segurar os demais Services.
	task.spawn(PlayCurrent)
end


return MusicService
