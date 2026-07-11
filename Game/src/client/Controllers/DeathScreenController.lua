--!strict
-- DeathScreenController (client)
-- Controla a DeathScreen (overlay de dano/morte) reagindo aos atributos Health/State do
-- personagem local (autoritativos no server via DownedService/RespawnService):
--
--   "Alive"  : a transparencia de MainFrame (BackgroundTransparency) e da Vignette (ImageTransparency)
--              acompanha a vida -> vida cheia = transparencia 1 (invisivel); vida 0 = transparencia 0
--              (tela vermelha totalmente visivel). Tween a cada mudanca de Health.
--   "Downed" : ambos voltam a ficar invisiveis (tween para 1).
--   "Dead"   : tween DIRETO para 0.3 em ambos e mostra o DiedInfo (botoes Respawn / BackToMenu).
--
-- Botoes (DiedInfo): Respawn -> pede LoadCharacter ao server (some se o player nao tem mais vidas);
-- BackToMenu -> pede teleporte ao Menu. Tambem desabilita o botao de reset padrao do Roblox.

local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

-- Vida maxima (espelha MAX_HEALTH do DownedService). Usada para normalizar a transparencia.
local MAX_HEALTH = 100
-- Transparencia de ambos os elementos quando o player esta morto (Dead).
local DEAD_TRANSPARENCY = 0.3
-- Duracao (s) dos tweens de transparencia.
local TWEEN_TIME = 0.35

local TWEEN_INFO = TweenInfo.new(TWEEN_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local DeathScreenController = {}
DeathScreenController.Gui = nil :: ScreenGui?
DeathScreenController.MainFrame = nil :: Frame?
DeathScreenController.Vignette = nil :: ImageLabel?
DeathScreenController.DiedInfo = nil :: Frame?
DeathScreenController.StateConnection = nil :: RBXScriptConnection?
DeathScreenController.HealthConnection = nil :: RBXScriptConnection?
DeathScreenController.MainTween = nil :: Tween?
DeathScreenController.VignetteTween = nil :: Tween?
-- Guardamos o BindableEvent do reset para nao ser coletado pelo GC (senao o reset volta a funcionar).
DeathScreenController.ResetBindable = nil :: BindableEvent?
DeathScreenController.RespawnRemote = nil :: RemoteEvent?
DeathScreenController.BackToMenuRemote = nil :: RemoteEvent?
-- Botoes (dentro de DiedInfo.Buttons), guardados no setup.
DeathScreenController.RespawnButton = nil :: GuiButton?
DeathScreenController.RespawnLabel = nil :: TextLabel?
DeathScreenController.SpectateButton = nil :: GuiButton?
DeathScreenController.BackToMenuButton = nil :: GuiButton?

-- Transparencia alvo a partir da vida: vida cheia -> 1 (invisivel), vida 0 -> 0 (visivel).
local function healthToTransparency(health: number): number
	return math.clamp(health / MAX_HEALTH, 0, 1)
end

-- Tween da transparencia de MainFrame e Vignette para o mesmo valor (cancela tweens em andamento).
function DeathScreenController:_tweenTo(transparency: number)
	if self.MainTween then
		self.MainTween:Cancel()
	end
	if self.VignetteTween then
		self.VignetteTween:Cancel()
	end

	if self.MainFrame then
		self.MainTween = TweenService:Create(self.MainFrame, TWEEN_INFO, { BackgroundTransparency = transparency })
		self.MainTween:Play()
	end
	if self.Vignette then
		self.VignetteTween = TweenService:Create(self.Vignette, TWEEN_INFO, { ImageTransparency = transparency })
		self.VignetteTween:Play()
	end
end

-- Spectate so faz sentido com outro player no servidor; some se o player estiver sozinho.
function DeathScreenController:_updateSpectateButton()
	local btn = self.SpectateButton
	if not btn then
		return
	end
	btn.Visible = #Players:GetPlayers() > 1
end

-- Atualiza a UI dependente das vidas (visibilidade/label do Respawn + TheText). Chamado ao mostrar
-- o DiedInfo e sempre que o atributo Lives mudar (ele replica do server e pode chegar depois do
-- State, entao refrescamos para o label nao ficar com o valor antigo).
function DeathScreenController:_refreshLivesUI()
	local diedInfo = self.DiedInfo
	if not diedInfo then
		return
	end
	local lives = LocalPlayer:GetAttribute("Lives")
	local hasLives = typeof(lives) == "number" and lives > 0

	-- Respawn so aparece se ainda ha vidas; sem vidas, so resta Spectate/BackToMenu.
	if self.RespawnButton then
		self.RespawnButton.Visible = hasLives
	end
	-- Texto do label dentro do botao Respawn com as vidas restantes.
	if self.RespawnLabel and typeof(lives) == "number" then
		self.RespawnLabel.Text = string.format("Respawn? (%d lifes left)", lives)
	end

	local text = diedInfo:FindFirstChild("TheText")
	if text and text:IsA("TextLabel") and typeof(lives) == "number" then
		text.Text = string.format("Você morreu — vidas restantes: %d", lives)
	end
end

-- Liga/desliga a ScreenGui inteira da DeathScreen. Usado pelo DownedController: a DeathScreen some
-- ao entrar em spectate e volta ao sair. Nao mexe no estado interno (DiedInfo/transparencia).
function DeathScreenController:SetScreenEnabled(enabled: boolean)
	if self.Gui then
		self.Gui.Enabled = enabled
	end
end

function DeathScreenController:_setDiedInfoVisible(visible: boolean)
	local diedInfo = self.DiedInfo
	if not diedInfo then
		return
	end
	diedInfo.Visible = visible

	if visible then
		self:_refreshLivesUI()
		-- Spectate some se o player estiver sozinho no servidor.
		self:_updateSpectateButton()
	end
end

-- Atualiza a transparencia pela vida (so vale enquanto Alive; Downed/Dead tem transparencia propria).
function DeathScreenController:_onHealthChanged(character: Model)
	if character:GetAttribute("State") ~= "Alive" then
		return
	end
	local health = character:GetAttribute("Health")
	if typeof(health) ~= "number" then
		return
	end
	self:_tweenTo(healthToTransparency(health))
end

function DeathScreenController:_onStateChanged(character: Model)
	local state = character:GetAttribute("State") or "Alive"

	if state == "Dead" then
		self:_tweenTo(DEAD_TRANSPARENCY)
		self:_setDiedInfoVisible(true)
	elseif state == "Downed" then
		self:_setDiedInfoVisible(false)
		self:_tweenTo(1) -- invisivel enquanto agonizando
	else -- "Alive"
		self:_setDiedInfoVisible(false)
		local health = character:GetAttribute("Health")
		local value = if typeof(health) == "number" then health else MAX_HEALTH
		self:_tweenTo(healthToTransparency(value))
	end
end

function DeathScreenController:_bindCharacter(character: Model)
	if self.StateConnection then
		self.StateConnection:Disconnect()
	end
	if self.HealthConnection then
		self.HealthConnection:Disconnect()
	end

	self.StateConnection = character:GetAttributeChangedSignal("State"):Connect(function()
		self:_onStateChanged(character)
	end)
	self.HealthConnection = character:GetAttributeChangedSignal("Health"):Connect(function()
		self:_onHealthChanged(character)
	end)

	-- Estado inicial do spawn (normalmente Alive, vida cheia -> invisivel).
	self:_onStateChanged(character)
end

-- Resolve a GUI + remotes e liga os botoes uma unica vez (a DeathScreen tem ResetOnSpawn=false,
-- entao persiste entre respawns; setup roda so no Start).
function DeathScreenController:_setupGui()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	local gui = playerGui:WaitForChild("DeathScreen", 30) :: ScreenGui?
	if not gui then
		warn("[DeathScreenController] DeathScreen nao encontrada na PlayerGui")
		return
	end
	gui.Enabled = true
	-- Fica acima da SpectateGui para que os botoes Respawn/BackToMenu sejam clicaveis quando morto.
	gui.DisplayOrder = 10
	self.Gui = gui

	local mainFrame = gui:WaitForChild("MainFrame") :: Frame
	self.MainFrame = mainFrame
	self.Vignette = mainFrame:WaitForChild("Vignette") :: ImageLabel
	self.DiedInfo = mainFrame:WaitForChild("DiedInfo") :: Frame

	-- Estado inicial: overlay invisivel e DiedInfo oculto.
	mainFrame.BackgroundTransparency = 1
	self.Vignette.ImageTransparency = 1
	self.DiedInfo.Visible = false

	-- Remotes (client -> server).
	local comms = ReplicatedStorage:WaitForChild("Comms")
	local deathFolder = comms:WaitForChild("Death")
	self.RespawnRemote = deathFolder:WaitForChild("Respawn") :: RemoteEvent
	self.BackToMenuRemote = deathFolder:WaitForChild("BackToMenu") :: RemoteEvent

	-- Os botoes agora ficam dentro de DiedInfo.Buttons (Respawn / Spectate / BackToMenu).
	local buttons = self.DiedInfo:WaitForChild("Buttons") :: Instance

	local respawnBtn = buttons:FindFirstChild("Respawn")
	if respawnBtn and respawnBtn:IsA("GuiButton") then
		self.RespawnButton = respawnBtn
		-- Label de texto dentro do botao (atualizado com as vidas restantes em _setDiedInfoVisible).
		self.RespawnLabel = respawnBtn:FindFirstChildWhichIsA("TextLabel", true)
		respawnBtn.Activated:Connect(function()
			if self.RespawnRemote then
				self.RespawnRemote:FireServer()
			end
		end)
	end

	local backBtn = buttons:FindFirstChild("BackToMenu")
	if backBtn and backBtn:IsA("GuiButton") then
		self.BackToMenuButton = backBtn
		backBtn.Activated:Connect(function()
			if self.BackToMenuRemote then
				self.BackToMenuRemote:FireServer()
			end
		end)
	end

	-- Spectate: so entra no modo espectador ao ser clicado (nao mais automaticamente na morte).
	-- Delega ao DownedController, que so permite spectar se o player estiver de fato morto.
	local spectateBtn = buttons:FindFirstChild("Spectate")
	if spectateBtn and spectateBtn:IsA("GuiButton") then
		self.SpectateButton = spectateBtn
		spectateBtn.Activated:Connect(function()
			local downed = self.GetController and self.GetController("DownedController")
			if downed then
				downed:EnterSpectate()
			end
		end)
	end

	-- Mantem a visibilidade do botao Spectate coerente quando players entram/saem enquanto morto.
	local function refreshSpectateIfDead()
		if self.DiedInfo and self.DiedInfo.Visible then
			self:_updateSpectateButton()
		end
	end
	Players.PlayerAdded:Connect(refreshSpectateIfDead)
	Players.PlayerRemoving:Connect(refreshSpectateIfDead)

	-- Vidas replicam do server (RespawnService desconta no State->Dead); refresca o label/TheText
	-- enquanto o DiedInfo estiver visivel para nao ficar com o numero antigo.
	LocalPlayer:GetAttributeChangedSignal("Lives"):Connect(function()
		if self.DiedInfo and self.DiedInfo.Visible then
			self:_refreshLivesUI()
		end
	end)

	-- Aplica o estado atual do personagem agora que a GUI existe.
	if LocalPlayer.Character then
		self:_onStateChanged(LocalPlayer.Character)
	end
end

-- Desabilita o botao de reset padrao do Roblox: aponta o ResetButtonCallback para um BindableEvent
-- que nunca faz nada (pressionar reset dispara ele em vez de resetar o personagem). Insiste ate o
-- CoreGui estar pronto (SetCore pode falhar no boot).
function DeathScreenController:_disableReset()
	local bindable = Instance.new("BindableEvent")
	self.ResetBindable = bindable

	task.spawn(function()
		while true do
			local ok = pcall(function()
				StarterGui:SetCore("ResetButtonCallback", bindable)
			end)
			if ok then
				break
			end
			task.wait(0.2)
		end
	end)
end

function DeathScreenController:Start()
	self:_disableReset()

	-- Setup da GUI em thread separada (WaitForChild pode bloquear); os binds de personagem abaixo
	-- ja funcionam mesmo antes da GUI resolver (os tweens ignoram frames ainda nil).
	task.spawn(function()
		self:_setupGui()
	end)

	if LocalPlayer.Character then
		self:_bindCharacter(LocalPlayer.Character)
	end
	LocalPlayer.CharacterAdded:Connect(function(character)
		self:_bindCharacter(character)
	end)

	print("✓ DeathScreenController initialized")
end

return DeathScreenController
