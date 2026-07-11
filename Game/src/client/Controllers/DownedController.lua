--!strict
-- DownedController (client)
-- Contraparte client do DownedService. Reage ao atributo State do PROPRIO personagem
-- (LocalPlayer.Character) e aplica os efeitos locais de cada estado:
--
--   "Downed": tela P&B (ColorCorrection), audio do mapa com reverb/fade, 3a pessoa (viewmodel
--             pausado + corpo revelado), WalkSpeed lenta + animacao de caido (HumanoidController)
--             e esconde o proprio ProximityPrompt de revive (que continua visivel para os outros).
--   "Alive" : reverte tudo (revive).
--   "Dead"  : entra em spectate — mostra a SpectateGui e coloca a camera em 3a pessoa dos outros
--             players vivos (Next/Previous ciclam). Botao "Revive?" e placeholder (sem acao).
--
-- O estado e autoritativo no server (via atributos); aqui so tratamos a experiencia local.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")

local LocalPlayer = Players.LocalPlayer

-- Nome do ColorCorrectionEffect de dessaturacao (P&B) criado no Lighting.
local DESATURATE_NAME = "DownedDesaturate"
-- Nome do ProximityPrompt de revive (criado no personagem pelo DownedService).
local REVIVE_PROMPT_NAME = "RevivePrompt"
-- Fator de volume aplicado aos audios do mapa enquanto downed (0..1). Menor = mais abafado.
local AUDIO_MUFFLE_FACTOR = 0.25
-- Zoom minimo (studs) forcado enquanto downed, para jogar a camera para a 3a pessoa.
local DOWNED_CAM_MIN_ZOOM = 10
-- Zoom minimo (studs) forcado na MORTE, para jogar a camera para a 3a pessoa automaticamente.
local DEAD_CAM_MIN_ZOOM = 10

-- Duracao (s) do estado downed antes da morte por timeout. ESPELHA DownedService.DOWNED_DURATION:
-- manter em sincronia com o server (a barra de downed anima com base neste tempo). Como o server
-- mata no fim do timer (State -> "Dead"), a barra e escondida nesse momento mesmo se nao zerou 100%.
local DOWNED_DURATION = 30
-- Cores da barra de downed: cheia = verde, perto de acabar = vermelho (transicao suave via Lerp).
local DOWNED_BAR_GREEN = Color3.fromRGB(8, 255, 24)
local DOWNED_BAR_RED = Color3.fromRGB(255, 0, 0)
-- Duracao (s) do fade da tela P&B.
local DESATURATE_FADE = 0.6

-- Limites de zoom da camera de spectate. Usamos a CAMERA PADRAO do Roblox (CameraType Custom +
-- CameraSubject), entao o player orbita/zooma livremente com colisao de parede (Popper). O min > 1
-- impede ficar em 1a pessoa; o max limita o zoom out.
local SPECTATE_MIN_ZOOM = 6
local SPECTATE_MAX_ZOOM = 24

local DownedController = {}

-- Estado local ja processado, para evitar reprocessar a mesma transicao.
DownedController.CurrentClientState = nil :: string?
-- Conexao do atributo State do personagem atual.
DownedController.StateConnection = nil :: RBXScriptConnection?
-- Originais de volume de audio (para restaurar ao sair do downed).
DownedController.AudioOriginals = nil :: { [Instance]: number }?
-- Wire re-roteado ao inserir o reverb (para restaurar).
DownedController.ReverbWire = nil :: any
-- Estado do spectate.
DownedController.Spectating = false
DownedController.SpectateTargets = {} :: { Player }
DownedController.SpectateIndex = 1
DownedController.SpectateGui = nil :: ScreenGui?
-- Conexoes que monitoram a validade do alvo atual (para trocar de alvo se ele morrer/sair).
DownedController.SpectateTargetConns = {} :: { RBXScriptConnection }
-- Se os efeitos de MORTE (viewmodel pausado + hotbar desativada) estao aplicados. Usado para
-- reverter no respawn de forma idempotente.
DownedController.DeadEffectsActive = false
-- Estado da barra de downed (StarterGui.DownedBar). Resolvida sob demanda (ResetOnSpawn re-clona).
DownedController.DownedBar = nil :: ScreenGui?
DownedController.DownedBarFill = nil :: Frame?
DownedController.DownedBarFullWidth = 0
DownedController.DownedBarStart = 0
DownedController.DownedBarConnection = nil :: RBXScriptConnection?


-- =========================================================================================
-- Helpers de acesso a outros controllers
-- =========================================================================================

function DownedController:_getViewmodel()
	local getController = self.GetController
	local vc = getController and getController("ViewmodelController")
	return vc and vc:GetViewmodel()
end

function DownedController:_getHumanoidController()
	local getController = self.GetController
	return getController and getController("HumanoidController")
end

function DownedController:_getHotbarController()
	local getController = self.GetController
	return getController and getController("HotbarHandlerController")
end

function DownedController:_getDeathScreenController()
	local getController = self.GetController
	return getController and getController("DeathScreenController")
end

-- Efeitos aplicados na MORTE real (State == "Dead"): desativa o viewmodel (esconde o modelo e
-- desliga o loop de render "ViewmodelUpdate" via :Pause) e a Hotbar (UI + binds). Idempotente.
function DownedController:_enterDead()
	if self.DeadEffectsActive then
		return
	end
	self.DeadEffectsActive = true

	local viewmodel = self:_getViewmodel()
	if viewmodel then
		viewmodel:Pause()
		-- Cursor visivel e destravado na DeathScreen. Tambem desliga o sway enquanto o mouse livre.
		viewmodel:SetFreeMouse(true)
	end

	-- Vai para 3a pessoa automaticamente na morte. SOBE o Max antes de subir o Min (o Roblox nao
	-- deixa o Min ficar acima do Max; vindo da 1a pessoa Max=0.5). Sair da 1a pessoa tambem impede
	-- o camera script padrao de re-travar o cursor no centro, deixando o mouse de fato livre.
	LocalPlayer.CameraMaxZoomDistance = 128
	LocalPlayer.CameraMinZoomDistance = DEAD_CAM_MIN_ZOOM

	local hotbar = self:_getHotbarController()
	if hotbar then
		hotbar:SetHotbarEnabled(false)
	end
end

-- Reverte os efeitos de morte no respawn: religa o viewmodel (:Resume rebinda o render e reexibe o
-- modelo) e a Hotbar. Idempotente (so age se estava morto).
function DownedController:_exitDead()
	if not self.DeadEffectsActive then
		return
	end
	self.DeadEffectsActive = false

	-- Respawn: volta para a 1a pessoa. BAIXA o Min ANTES do Max (o Roblox nao deixa o Max ficar
	-- abaixo do Min; vindo da morte Min=10). Feito antes do SetFreeMouse(false) para o cursor
	-- travar corretamente no centro da 1a pessoa.
	LocalPlayer.CameraMinZoomDistance = 0.5
	LocalPlayer.CameraMaxZoomDistance = 0.5

	local viewmodel = self:_getViewmodel()
	if viewmodel then
		viewmodel:Resume()
		-- Respawn: volta a esconder/travar o cursor no centro (1a pessoa).
		viewmodel:SetFreeMouse(false)
	end

	local hotbar = self:_getHotbarController()
	if hotbar then
		hotbar:SetHotbarEnabled(true)
	end
end


-- =========================================================================================
-- Efeitos de DOWNED
-- =========================================================================================

-- Mostra/esconde o corpo do personagem local (o Viewmodel esconde tudo menos a Head em 1a
-- pessoa; na 3a pessoa do downed precisamos revelar o corpo, e re-esconder ao voltar).
function DownedController:_setBodyHidden(hidden: boolean)
	local character = LocalPlayer.Character
	if not character then
		return
	end
	for _, part in ipairs(character:GetDescendants()) do
		if part:IsA("BasePart") and part.Name ~= "Head" then
			part.LocalTransparencyModifier = hidden and 1 or 0
		end
	end
end

-- Cria (ou remove) o efeito P&B no Lighting, com fade.
function DownedController:_setDesaturate(enabled: boolean)
	local existing = Lighting:FindFirstChild(DESATURATE_NAME) :: ColorCorrectionEffect?

	if enabled then
		if not existing then
			existing = Instance.new("ColorCorrectionEffect")
			existing.Name = DESATURATE_NAME
			existing.Saturation = 0
			existing.Contrast = 0
			existing.Parent = Lighting
		end
		TweenService:Create(existing, TweenInfo.new(DESATURATE_FADE), {
			Saturation = -1,
			Contrast = 0.1,
		}):Play()
	elseif existing then
		local tween = TweenService:Create(existing, TweenInfo.new(DESATURATE_FADE), {
			Saturation = 0,
			Contrast = 0,
		})
		tween.Completed:Connect(function()
			if existing and existing.Parent then
				existing:Destroy()
			end
		end)
		tween:Play()
	end
end

-- Insere/remove um AudioReverb na cadeia do AudioListener local (afeta so o que ESTE client
-- ouve). Best-effort: se a cadeia esperada nao existir, apenas ignora.
function DownedController:_setReverb(enabled: boolean)
	local character = LocalPlayer.Character
	local head = character and character:FindFirstChild("Head")
	local listener = head and head:FindFirstChild("CharacterAudioListener")
	if not listener then
		return
	end
	local output = listener:FindFirstChildOfClass("AudioDeviceOutput")
	if not output then
		return
	end

	if enabled then
		-- Acha o Wire que liga o Output do listener a entrada da saida de audio.
		local wire: Wire? = nil
		for _, w in ipairs(output:GetChildren()) do
			if w:IsA("Wire") and w.SourceInstance == listener then
				wire = w
				break
			end
		end
		if not wire then
			return
		end

		local reverb = Instance.new("AudioReverb")
		reverb.Name = "DownedReverb"
		reverb.DecayTime = 2.5
		reverb.WetLevel = 6
		reverb.Parent = listener

		-- Reroteia: listener.Output -> reverb.Input, reverb.Output -> output.Input.
		wire.TargetInstance = reverb
		wire.TargetName = "Input"

		local outWire = Instance.new("Wire")
		outWire.Name = "DownedReverbWire"
		outWire.SourceInstance = reverb
		outWire.SourceName = "Output"
		outWire.TargetInstance = output
		outWire.TargetName = "Input"
		outWire.Parent = reverb

		self.ReverbWire = wire
	else
		local reverb = listener:FindFirstChild("DownedReverb")
		if self.ReverbWire and output then
			-- Restaura o wire original: listener.Output -> output.Input.
			self.ReverbWire.TargetInstance = output
			self.ReverbWire.TargetName = "Input"
		end
		self.ReverbWire = nil
		if reverb then
			reverb:Destroy()
		end
	end
end

-- Faz fade (ou restaura) o volume dos audios do mapa atual. Writes locais no client (nao
-- replicam), entao so este player experimenta o abafamento.
function DownedController:_setMapAudioMuffled(enabled: boolean)
	if enabled then
		local originals: { [Instance]: number } = {}
		local container = Workspace:FindFirstChild("MapInUse")
		local activeMap = container and container:FindFirstChild("ActiveMap")
		if activeMap then
			for _, d in ipairs(activeMap:GetDescendants()) do
				if d:IsA("AudioPlayer") or d:IsA("Sound") then
					originals[d] = (d :: any).Volume
					;(d :: any).Volume = (d :: any).Volume * AUDIO_MUFFLE_FACTOR
				end
			end
		end
		self.AudioOriginals = originals
	else
		if self.AudioOriginals then
			for inst, vol in pairs(self.AudioOriginals) do
				if inst.Parent then
					(inst :: any).Volume = vol
				end
			end
		end
		self.AudioOriginals = nil
	end
end

-- Esconde o proprio prompt de revive (write client-only: some so para este player). O prompt
-- pode chegar depois do atributo State, entao esperamos por ele com um curto timeout.
function DownedController:_hideOwnRevivePrompt()
	local character = LocalPlayer.Character
	if not character then
		return
	end
	task.spawn(function()
		local root = character:FindFirstChild("HumanoidRootPart")
		if not root then
			return
		end
		local prompt = root:FindFirstChild(REVIVE_PROMPT_NAME)
		if not prompt then
			prompt = root:WaitForChild(REVIVE_PROMPT_NAME, 3)
		end
		-- So esconde se ainda estivermos downed (evita esconder um prompt de um downed futuro).
		if prompt and prompt:IsA("ProximityPrompt") and self.CurrentClientState == "Downed" then
			prompt.Enabled = false
		end
	end)
end

-- =========================================================================================
-- Barra de downed (StarterGui.DownedBar): encolhe com o tempo restante para ser revivido e
-- transiciona de verde (cheia) para vermelho (perto de acabar). O tempo total espelha o server.
-- =========================================================================================

-- Resolve a UI sob demanda (a DownedBar tem ResetOnSpawn=true, entao e re-clonada a cada respawn;
-- uma referencia cacheada ficaria obsoleta). Retorna (ScreenGui, Frame do fill) ou nil.
function DownedController:_resolveDownedBar(): (ScreenGui?, Frame?)
	local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
	local bar = playerGui and playerGui:FindFirstChild("DownedBar")
	local frame = bar and bar:FindFirstChild("Frame")
	local fill = frame and frame:FindFirstChild("Bar")
	if bar and bar:IsA("ScreenGui") and fill and fill:IsA("Frame") then
		return bar, fill
	end
	return nil, nil
end

-- Atualiza (todo frame) a largura e a cor do fill conforme o tempo decorrido de downed.
function DownedController:_updateDownedBar()
	local fill = self.DownedBarFill
	if not fill or not fill.Parent then
		return
	end
	local elapsed = os.clock() - self.DownedBarStart
	local progress = math.clamp(elapsed / DOWNED_DURATION, 0, 1) -- 0 no inicio, 1 no fim
	local remaining = 1 - progress

	local size = fill.Size
	-- Encolhe so a largura (X.Scale), preservando o resto do UDim2.
	fill.Size = UDim2.new(self.DownedBarFullWidth * remaining, size.X.Offset, size.Y.Scale, size.Y.Offset)
	-- Verde (cheia) -> vermelho (fim), transicao suave.
	fill.BackgroundColor3 = DOWNED_BAR_GREEN:Lerp(DOWNED_BAR_RED, progress)
end

function DownedController:_startDownedBar()
	local bar, fill = self:_resolveDownedBar()
	if not bar or not fill then
		return
	end

	self.DownedBar = bar
	self.DownedBarFill = fill
	-- Largura "cheia" = a largura autorada da barra (respeita o que foi montado na UI).
	self.DownedBarFullWidth = fill.Size.X.Scale
	self.DownedBarStart = os.clock()

	fill.BackgroundColor3 = DOWNED_BAR_GREEN
	bar.Enabled = true

	if self.DownedBarConnection then
		self.DownedBarConnection:Disconnect()
	end
	self.DownedBarConnection = RunService.RenderStepped:Connect(function()
		self:_updateDownedBar()
	end)
	self:_updateDownedBar()
end

function DownedController:_stopDownedBar()
	if self.DownedBarConnection then
		self.DownedBarConnection:Disconnect()
		self.DownedBarConnection = nil
	end

	local bar = self.DownedBar
	local fill = self.DownedBarFill
	-- Reseta a barra para cheia + verde e esconde (guardas contra instancias ja destruidas no respawn).
	if fill and fill.Parent then
		local size = fill.Size
		fill.Size = UDim2.new(self.DownedBarFullWidth, size.X.Offset, size.Y.Scale, size.Y.Offset)
		fill.BackgroundColor3 = DOWNED_BAR_GREEN
	end
	if bar and bar.Parent then
		bar.Enabled = false
	end

	self.DownedBar = nil
	self.DownedBarFill = nil
end

function DownedController:_enterDowned()
	-- Barra de downed: aparece e comeca a contar/encolher.
	self:_startDownedBar()

	-- Efeitos visuais/audio locais.
	self:_setDesaturate(true)
	pcall(function()
		self:_setReverb(true)
	end)
	self:_setMapAudioMuffled(true)

	-- 3a pessoa: pausa o viewmodel, libera o zoom e revela o corpo.
	local viewmodel = self:_getViewmodel()
	if viewmodel then
		viewmodel:Pause()
		viewmodel:SetFirstPerson(false)
	end
	self:_setBodyHidden(false)
	-- 3a pessoa: SOBE o Max antes de subir o Min (o Roblox nao deixa o Min ficar acima do Max;
	-- vindo da 1a pessoa Max=0.5, entao subir o Min primeiro seria clampado).
	LocalPlayer.CameraMaxZoomDistance = 128
	LocalPlayer.CameraMinZoomDistance = DOWNED_CAM_MIN_ZOOM

	-- WalkSpeed lenta + animacao de caido.
	local humanoidController = self:_getHumanoidController()
	if humanoidController then
		humanoidController:SetDowned(true)
	end

	-- Desativa a Hotbar enquanto caido (UI + binds). Religa so ao ser levantado (transicao
	-- Downed -> Alive) ou ao respawnar (via _exitDead). NAO religamos no _exitDowned porque ele
	-- tambem roda no caminho Downed -> Dead, onde a hotbar deve continuar desativada.
	local hotbar = self:_getHotbarController()
	if hotbar then
		hotbar:SetHotbarEnabled(false)
	end

	self:_hideOwnRevivePrompt()
end

function DownedController:_exitDowned()
	-- Esconde/reseta a barra de downed (revive ou morte por timeout).
	self:_stopDownedBar()

	self:_setDesaturate(false)
	pcall(function()
		self:_setReverb(false)
	end)
	self:_setMapAudioMuffled(false)

	local humanoidController = self:_getHumanoidController()
	if humanoidController then
		humanoidController:SetDowned(false)
	end

	-- Volta a 1a pessoa. IMPORTANTE: BAIXA o Min ANTES do Max — o Roblox nao deixa o Max ficar
	-- abaixo do Min (ele clampa), entao vindo do downed (Min=10) o SetFirstPerson (que baixa o Max
	-- primeiro) nao conseguiria descer o zoom e a camera ficaria travada em 3a pessoa. Fazemos o
	-- reset direto aqui (independente do viewmodel) para garantir a 1a pessoa mesmo se ele faltar.
	LocalPlayer.CameraMinZoomDistance = 0.5
	LocalPlayer.CameraMaxZoomDistance = 0.5

	-- Religa o viewmodel (render step: bounce/sway/offset + bracos) e trava mouse/zoom em 1a pessoa.
	local viewmodel = self:_getViewmodel()
	if viewmodel then
		viewmodel:Resume()
		viewmodel:SetFirstPerson(true)
	end

	self:_setBodyHidden(true)
end


-- =========================================================================================
-- Spectate (estado Dead)
-- =========================================================================================

-- Lista de alvos validos para spectar: outros players vivos com personagem.
function DownedController:_refreshSpectateTargets()
	local targets: { Player } = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= LocalPlayer then
			local character = player.Character
			local state = character and character:GetAttribute("State")
			if character and character:FindFirstChild("HumanoidRootPart") and state ~= "Dead" then
				table.insert(targets, player)
			end
		end
	end
	self.SpectateTargets = targets
	if self.SpectateIndex > #targets then
		self.SpectateIndex = 1
	end
end

function DownedController:_cycleSpectate(delta: number)
	self:_refreshSpectateTargets()
	local count = #self.SpectateTargets
	if count == 0 then
		return
	end
	self.SpectateIndex = ((self.SpectateIndex - 1 + delta) % count) + 1
	self:_applySpectateSubject()
end

function DownedController:_enterSpectate()
	if self.Spectating then
		return
	end
	self.Spectating = true

	-- Garante que os efeitos de downed sairam (caso venha de Downed -> Dead).
	self:_setDesaturate(false)
	pcall(function()
		self:_setReverb(false)
	end)
	self:_setMapAudioMuffled(false)

	self:_refreshSpectateTargets()
	self.SpectateIndex = 1

	local gui = self.SpectateGui
	if gui then
		gui.Enabled = true
	end

	-- Esconde a DeathScreen enquanto espectando (volta ao sair do spectate).
	local deathScreen = self:_getDeathScreenController()
	if deathScreen then
		deathScreen:SetScreenEnabled(false)
	end

	-- Usa a CAMERA PADRAO do Roblox: apenas apontamos o CameraSubject para o Humanoid do alvo.
	-- Assim o player orbita a camera e da zoom livremente (com colisao de parede/Popper), SEM
	-- RenderStep posicionando a camera (nada de camera "presa" ao alvo).
	local camera = Workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Custom
	LocalPlayer.CameraMode = Enum.CameraMode.Classic
	-- Zoom limitado: min > 1 impede 1a pessoa; max limita o zoom out.
	LocalPlayer.CameraMinZoomDistance = SPECTATE_MIN_ZOOM
	LocalPlayer.CameraMaxZoomDistance = SPECTATE_MAX_ZOOM

	self:_applySpectateSubject()
end

-- Desconecta os watchers do alvo atual.
function DownedController:_clearSpectateTargetConns()
	for _, conn in ipairs(self.SpectateTargetConns) do
		conn:Disconnect()
	end
	self.SpectateTargetConns = {}
end

-- Aponta o CameraSubject para o Humanoid do alvo atual (a camera padrao cuida de orbita/zoom/
-- colisao). Monitora o alvo: se ele morrer (State -> "Dead") ou seu personagem sair, avanca
-- automaticamente para o proximo. Nao usa RenderStep.
function DownedController:_applySpectateSubject()
	self:_clearSpectateTargetConns()

	local target = self.SpectateTargets[self.SpectateIndex]
	local character = target and target.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not target or not character or not humanoid then
		return
	end

	Workspace.CurrentCamera.CameraSubject = humanoid

	table.insert(self.SpectateTargetConns, character:GetAttributeChangedSignal("State"):Connect(function()
		if self.Spectating and character:GetAttribute("State") == "Dead" then
			self:_cycleSpectate(1)
		end
	end))
	table.insert(self.SpectateTargetConns, target.CharacterRemoving:Connect(function()
		if self.Spectating then
			self:_cycleSpectate(1)
		end
	end))
end

function DownedController:_exitSpectate()
	if not self.Spectating then
		return
	end
	self.Spectating = false

	self:_clearSpectateTargetConns()

	local gui = self.SpectateGui
	if gui then
		gui.Enabled = false
	end

	-- Sair do spectate: religa a DeathScreen (pronta para o estado atual/mortes futuras). O
	-- DeathScreenController reprocessa o estado no respawn/revive (Alive esconde o DiedInfo).
	local deathScreen = self:_getDeathScreenController()
	if deathScreen then
		deathScreen:SetScreenEnabled(true)
	end

	-- Restaura a camera para o proprio player. A camera padrao ja reaponta o subject ao respawnar,
	-- mas garantimos aqui; os limites de zoom sao redefinidos pelo _exitDead (1a pessoa) no respawn.
	local camera = Workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Custom
	local ownCharacter = LocalPlayer.Character
	local ownHumanoid = ownCharacter and ownCharacter:FindFirstChildOfClass("Humanoid")
	if ownHumanoid then
		camera.CameraSubject = ownHumanoid
	end
end

-- API publica para a DeathScreen: entra em spectate SO se o player estiver morto (o botao
-- Spectate da DeathScreen chama isto). _enterSpectate ja ignora chamadas repetidas.
function DownedController:EnterSpectate()
	if self.CurrentClientState ~= "Dead" then
		return
	end
	self:_enterSpectate()
end

function DownedController:ExitSpectate()
	self:_exitSpectate()
end

function DownedController:IsSpectating(): boolean
	return self.Spectating
end


-- =========================================================================================
-- Dispatch por estado + ciclo de vida
-- =========================================================================================

function DownedController:_onStateChanged(newState: string?)
	newState = newState or "Alive"
	if newState == self.CurrentClientState then
		return
	end
	local previous = self.CurrentClientState
	self.CurrentClientState = newState

	if newState == "Downed" then
		if self.Spectating then
			self:_exitSpectate()
		end
		self:_enterDowned()
	elseif newState == "Dead" then
		if previous == "Downed" then
			self:_exitDowned()
		end
		-- O spectate NAO e mais ativado automaticamente na morte: o player entra nele so ao
		-- clicar no botao Spectate da DeathScreen (DeathScreenController -> :EnterSpectate).
		-- Desativa viewmodel + hotbar (revertidos no respawn via _exitDead). Roda DEPOIS do
		-- _exitDowned (que religa o viewmodel), garantindo o estado final pausado.
		self:_enterDead()
	else -- "Alive"
		if self.Spectating then
			self:_exitSpectate()
		end
		if previous == "Downed" then
			self:_exitDowned()
			-- Levantado: religa a Hotbar (desativada no _enterDowned). Feito aqui, e nao no
			-- _exitDowned, para NAO religar no caminho Downed -> Dead.
			local hotbar = self:_getHotbarController()
			if hotbar then
				hotbar:SetHotbarEnabled(true)
			end
		end
	end
end

function DownedController:_bindCharacter(character: Model)
	if self.StateConnection then
		self.StateConnection:Disconnect()
		self.StateConnection = nil
	end

	-- Novo personagem (respawn): começa vivo; garante saida de qualquer spectate.
	self.CurrentClientState = nil
	if self.Spectating then
		self:_exitSpectate()
	end

	-- Respawn: reverte os efeitos de morte (religa viewmodel + hotbar), se estavam ativos.
	self:_exitDead()

	-- Garante que a barra de downed nao fique pendurada de um estado anterior.
	self:_stopDownedBar()

	self.StateConnection = character:GetAttributeChangedSignal("State"):Connect(function()
		self:_onStateChanged(character:GetAttribute("State"))
	end)

	-- Processa o estado atual (normalmente "Alive" no spawn).
	self:_onStateChanged(character:GetAttribute("State"))
end

-- Liga os botoes da SpectateGui uma unica vez (Next/Previous ciclam; Revive e placeholder).
function DownedController:_setupSpectateGui()
	task.spawn(function()
		local playerGui = LocalPlayer:WaitForChild("PlayerGui")
		local gui = playerGui:WaitForChild("SpectateGui", 30) :: ScreenGui?
		if not gui then
			warn("[DownedController] SpectateGui nao encontrada na PlayerGui")
			return
		end
		gui.Enabled = false
		self.SpectateGui = gui

		local controls = gui:FindFirstChild("Controls")
		local nextBtn = controls and controls:FindFirstChild("Next")
		local prevBtn = controls and controls:FindFirstChild("Previous")

		if nextBtn and nextBtn:IsA("GuiButton") then
			nextBtn.Activated:Connect(function()
				if self.Spectating then
					self:_cycleSpectate(1)
				end
			end)
		end
		if prevBtn and prevBtn:IsA("GuiButton") then
			prevBtn.Activated:Connect(function()
				if self.Spectating then
					self:_cycleSpectate(-1)
				end
			end)
		end
		-- Botao "Revive" (Controls.Revive): placeholder, sem acao por enquanto.
	end)
end

function DownedController:Start()
	self:_setupSpectateGui()

	if LocalPlayer.Character then
		self:_bindCharacter(LocalPlayer.Character)
	end
	LocalPlayer.CharacterAdded:Connect(function(character)
		self:_bindCharacter(character)
	end)

	print("✓ DownedController initialized")
end


return DownedController
