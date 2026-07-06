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
-- Duracao (s) do fade da tela P&B.
local DESATURATE_FADE = 0.6

-- Camera de spectate (3a pessoa fixa atras do alvo).
local SPECTATE_CAM_DISTANCE = 12
local SPECTATE_CAM_HEIGHT = 3

local SPECTATE_RENDER_NAME = "SpectateCamera"

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

function DownedController:_enterDowned()
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

	self:_hideOwnRevivePrompt()
end

function DownedController:_exitDowned()
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

	local camera = Workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Scriptable

	RunService:BindToRenderStep(SPECTATE_RENDER_NAME, Enum.RenderPriority.Camera.Value + 1, function()
		self:_updateSpectateCamera(camera)
	end)
end

function DownedController:_updateSpectateCamera(camera: Camera)
	local target = self.SpectateTargets[self.SpectateIndex]
	local character = target and target.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	-- Camera fixa atras e um pouco acima do alvo, olhando para ele.
	local base = root.CFrame * CFrame.new(0, SPECTATE_CAM_HEIGHT, SPECTATE_CAM_DISTANCE)
	local lookAt = root.Position + Vector3.new(0, SPECTATE_CAM_HEIGHT * 0.5, 0)
	camera.CFrame = CFrame.lookAt(base.Position, lookAt)
end

function DownedController:_exitSpectate()
	if not self.Spectating then
		return
	end
	self.Spectating = false

	RunService:UnbindFromRenderStep(SPECTATE_RENDER_NAME)

	local gui = self.SpectateGui
	if gui then
		gui.Enabled = false
	end

	local camera = Workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Custom
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
		self:_enterSpectate()
	else -- "Alive"
		if self.Spectating then
			self:_exitSpectate()
		end
		if previous == "Downed" then
			self:_exitDowned()
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
