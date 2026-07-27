--!strict
-- VoiceNoiseController (client)
-- Transforma a VOZ do jogador local em barulho para a IA: mede o nivel do proprio microfone e
-- reporta ao server (Comms.Noise.ReportVoice), que o converte num evento do NoiseService na posicao
-- do personagem. E como o BusinessMan (cego) te ouve falar.
--
-- Por que isto tem de ser no client: o processamento de audio e DESLIGADO no server —
-- AudioAnalyzer.RmsLevel/PeakLevel sao "Not Replicated" e retornam sempre 0 la. O nivel do mic so
-- existe na maquina do dono. O server NAO confia em nada disto alem do numero: ele ignora qualquer
-- posicao, usa o HumanoidRootPart do remetente e limita a taxa (ver NoiseService).
--
-- Cadeia montada aqui (toda LOCAL, nao replica):
--   AudioDeviceInput (do LocalPlayer, criado pelo engine com o voice chat ligado)
--     --Wire--> AudioAnalyzer  -> RmsLevel/PeakLevel
--
-- NAO criamos o AudioDeviceInput (CreateIfMissing = false por padrao): com
-- VoiceChatService.UseAudioApi em "Automatic" quem o cria e o engine, e instanciar um segundo
-- poderia baguncar o voice chat do jogo. Sem ele (jogador sem mic / sem verificacao de idade),
-- o controller simplesmente nao liga — nenhuma outra parte do sistema depende desta fonte.
--
-- RISCO CONHECIDO: ha relatos de RmsLevel/PeakLevel voltando 0 justamente quando ligados a um
-- AudioDeviceInput (regressao do engine, sem resposta oficial). Por isso o LogSeconds abaixo:
-- os primeiros segundos logam o nivel medido no output do Studio. Se vier sempre 0, e o bug — basta
-- deixar Enabled = false aqui (ou VoiceEnabled = false no NoiseService) e o resto continua igual.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

local CONFIG = {
	-- Desligue aqui se o RmsLevel estiver zerado (ver acima) ou se nao quiser voz como barulho.
	Enabled = true,
	-- Intervalo (s) entre leituras do nivel. Casa com o VoiceMinInterval do NoiseService.
	PollInterval = 0.2,
	-- Nivel (0..1) abaixo do qual tratamos como silencio/ruido de fundo do microfone.
	Threshold = 0.02,
	-- Quantos segundos esperar pelo AudioDeviceInput do engine antes de desistir silenciosamente.
	DeviceWaitTime = 20,
	-- Loga o nivel medido durante os primeiros N segundos (diagnostico do bug do RmsLevel).
	-- 0 desliga o log.
	LogSeconds = 60,
	-- Cria o AudioDeviceInput se o engine nao tiver criado. Deixe FALSE a menos que o log mostre
	-- que ele nunca aparece: criar um segundo pode duplicar/quebrar o voice chat.
	CreateIfMissing = false,
}

local VoiceNoiseController = {}

-- Acha (ou, se CreateIfMissing, cria) o AudioDeviceInput do jogador local. Retorna nil se o voice
-- chat nao estiver disponivel para este jogador.
function VoiceNoiseController:_resolveDeviceInput(): AudioDeviceInput?
	local existing = LocalPlayer:FindFirstChildOfClass("AudioDeviceInput")
	if existing then
		return existing
	end

	-- O engine cria o AudioDeviceInput de forma assincrona no boot do voice chat; espera um pouco.
	local deadline = os.clock() + CONFIG.DeviceWaitTime
	while os.clock() < deadline do
		task.wait(0.5)
		local found = LocalPlayer:FindFirstChildOfClass("AudioDeviceInput")
		if found then
			return found
		end
	end

	if not CONFIG.CreateIfMissing then
		return nil
	end

	local input = Instance.new("AudioDeviceInput")
	input.Player = LocalPlayer
	input.Parent = LocalPlayer
	return input
end

-- Monta o AudioAnalyzer ligado ao microfone. Ambos sao criados NO CLIENT: nao replicam, e nao
-- interferem no audio que os outros jogadores ouvem (o analyzer so le, nao e um destino de saida).
function VoiceNoiseController:_setupAnalyzer(deviceInput: AudioDeviceInput): AudioAnalyzer
	local analyzer = Instance.new("AudioAnalyzer")
	analyzer.Name = "VoiceNoiseAnalyzer"
	analyzer.Parent = deviceInput

	local wire = Instance.new("Wire")
	wire.SourceInstance = deviceInput
	wire.SourceName = "Output"
	wire.TargetInstance = analyzer
	wire.TargetName = "Input"
	wire.Parent = analyzer

	return analyzer
end

-- Loop de medicao: le o nivel e, acima do Threshold, reporta ao server.
function VoiceNoiseController:_run(analyzer: AudioAnalyzer, remote: RemoteEvent)
	local startedAt = os.clock()
	local loggedAny = false

	while true do
		task.wait(CONFIG.PollInterval)

		-- RmsLevel e a energia media (melhor para "quao alto esta falando"); o PeakLevel pega
		-- transientes que o RMS suaviza. Ficamos com o maior dos dois.
		local level = math.max(analyzer.RmsLevel, analyzer.PeakLevel)

		if CONFIG.LogSeconds > 0 and os.clock() - startedAt < CONFIG.LogSeconds then
			if level > 0 then
				if not loggedAny then
					loggedAny = true
					print(string.format("[VoiceNoise] microfone OK — nivel medido: %.4f", level))
				end
			end
		elseif CONFIG.LogSeconds > 0 and not loggedAny then
			-- Passou a janela de diagnostico sem nunca ler nada > 0.
			CONFIG.LogSeconds = 0 -- nao repete o aviso
			warn("[VoiceNoise] AudioAnalyzer nunca leu nivel > 0 do microfone. "
				.. "Pode ser o bug conhecido do RmsLevel com AudioDeviceInput, mic mudo, ou voice "
				.. "chat indisponivel. A voz nao vai gerar barulho para a IA.")
		end

		if level >= CONFIG.Threshold then
			remote:FireServer(level)
		end
	end
end

function VoiceNoiseController:Start()
	if not CONFIG.Enabled then
		return
	end

	-- Tudo assincrono: espera pelo remote e pelo AudioDeviceInput sem segurar o loop de Start dos
	-- demais Controllers.
	task.spawn(function()
		local comms = ReplicatedStorage:WaitForChild("Comms")
		local noise = comms:WaitForChild("Noise")
		local remote = noise:WaitForChild("ReportVoice") :: RemoteEvent

		local deviceInput = self:_resolveDeviceInput()
		if not deviceInput then
			-- Sem voice chat para este jogador: fonte de barulho por voz simplesmente nao existe.
			return
		end

		local analyzer = self:_setupAnalyzer(deviceInput)
		self:_run(analyzer, remote)
	end)

	print("✓ VoiceNoiseController initialized")
end

return VoiceNoiseController
