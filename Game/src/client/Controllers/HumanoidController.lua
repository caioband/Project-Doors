--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DeviceController = require(ReplicatedStorage.Shared.SharedModules.DeviceController)

local LocalPlayer = Players.LocalPlayer

local DEFAULT_PROPERTIES = {
	WalkSpeed = 8,
	JumpPower = 50,
	JumpHeight = 7.2,
	AutoRotate = true,
	UseJumpPower = true,
}

-- Ids de animação customizadas (preencher com os asset ids desejados).
-- "Crouch" é uma subcategoria: ao agachar trocamos Idle/Walk pelas versões agachadas
-- (carregadas como tracks "CrouchIdle"/"CrouchWalk" — ver :SetupAnimations).
local ANIMATION_IDS = {
	Idle = "rbxassetid://124346862153043",
	Walk = "rbxassetid://133908840566076",
	Run = "rbxassetid://136145008370352",
	Crouch = {
		Idle = "rbxassetid://106749080125797",
		Walk = "rbxassetid://81202287295514",
	},
}

-- Velocidades de referência para escalar a velocidade de reprodução das animações
local WALK_BASE_SPEED = 8
local RUN_BASE_SPEED = 16

-- Limiares de velocidade para troca de animação
local WALK_MIN_SPEED = 7
local WALK_MAX_SPEED = 14

-- Acima desta velocidade (em pé ou agachado) o player é considerado em movimento.
local MOVE_MIN_SPEED = 0.5

-- Configuração do agachar (tudo ajustável).
local CROUCH_CONFIG = {
	-- WalkSpeed do player agachado.
	WalkSpeed = 3,
	-- Quanto a câmera/viewmodel abaixa (studs) ao agachar.
	CameraDip = 1.2,
	-- Velocidade de interpolação do abaixar/levantar da câmera.
	TransitionSpeed = 10,
	-- Binds: PC (tecla) e Console (botão). Mobile usa o botão de toque criado abaixo.
	KeyboardKey = Enum.KeyCode.LeftControl,
	GamepadKey = Enum.KeyCode.ButtonR3,
	-- Posição (em Scale) do botão de agachar no mobile — um pouco acima do botão de pular.
	MobileButtonPosition = UDim2.fromScale(0.82, 0.62),
	MobileButtonSize = UDim2.fromScale(0.09, 0.09),
}

local CROUCH_ACTION = "Crouch"

local HumanoidController = {}
HumanoidController.Humanoid = nil :: Humanoid?
HumanoidController.Animator = nil :: Animator?
HumanoidController.RootPart = nil :: BasePart?
HumanoidController.Tracks = {} :: { [string]: AnimationTrack }
HumanoidController.CurrentState = nil :: string?
HumanoidController.AnimationConnection = nil :: RBXScriptConnection?
HumanoidController.Overrides = {}
-- Estado do agachar
HumanoidController.IsCrouching = false
-- Quantidade interpolada (0 = em pé, 1 = agachado) usada para abaixar câmera/viewmodel.
HumanoidController.CrouchAmount = 0
-- Offset base da câmera (capturado do viewmodel) sobre o qual aplicamos o dip do agachar.
HumanoidController.BaseCameraOffset = nil :: CFrame?
HumanoidController.CrouchInputReady = false
HumanoidController.MobileCrouchButton = nil

function HumanoidController:Start()
	local function onCharacterAdded(character: Model)
		local humanoid = character:WaitForChild("Humanoid") :: Humanoid
		self.Humanoid = humanoid
		self.RootPart = character:WaitForChild("HumanoidRootPart") :: BasePart

		-- Cada respawn começa em pé.
		self.IsCrouching = false

		self:DisableDefaultAnimations(character)
		self:SetupAnimations(humanoid)
		self:StartAnimationLoop()

		self:ApplyOverrides()
	end

	if LocalPlayer.Character then
		onCharacterAdded(LocalPlayer.Character)
	end

	LocalPlayer.CharacterAdded:Connect(onCharacterAdded)

	-- Binds de agachar (uma única vez): tecla no PC, botão no console e botão de toque no mobile.
	self:SetupCrouchInput()

	print("✓ HumanoidController initialized")
end

-- Remove o script "Animate" padrão do Roblox para que nenhuma animação default toque
function HumanoidController:DisableDefaultAnimations(character: Model)
	local animateScript = character:FindFirstChild("Animate")
	if animateScript then
		(animateScript :: any).Disabled = true
		animateScript:Destroy()
	end
end

-- Carrega as animações customizadas no Animator
function HumanoidController:SetupAnimations(humanoid: Humanoid)
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	self.Animator = animator

	-- Limpa tracks antigas (de um character anterior)
	self.Tracks = {}
	self.CurrentState = nil

	local function loadTrack(name: string, id: string)
		local animation = Instance.new("Animation")
		animation.Name = name
		animation.AnimationId = id

		local track = (animator :: Animator):LoadAnimation(animation)
		track.Priority = Enum.AnimationPriority.Movement
		track.Looped = true
		self.Tracks[name] = track
	end

	-- Carrega tanto as animações simples (Idle/Walk/Run) quanto as subcategorias (ex.: Crouch),
	-- que viram tracks com nome composto: "CrouchIdle", "CrouchWalk".
	for name, id in pairs(ANIMATION_IDS) do
		if type(id) == "table" then
			for subName, subId in pairs(id) do
				loadTrack(name .. subName, subId)
			end
		else
			loadTrack(name, id)
		end
	end
end

-- Inicia o loop que decide qual animação tocar com base na velocidade da rootpart
function HumanoidController:StartAnimationLoop()
	if self.AnimationConnection then
		self.AnimationConnection:Disconnect()
		self.AnimationConnection = nil
	end

	self.AnimationConnection = RunService.RenderStepped:Connect(function(deltaTime)
		self:UpdateCrouchOffset(deltaTime)
		self:UpdateAnimation()
	end)
end

-- Avalia a velocidade horizontal e toca a animação apropriada
function HumanoidController:UpdateAnimation()
	local rootPart = self.RootPart
	if not rootPart or not rootPart.Parent then
		return
	end

	local velocity = rootPart.AssemblyLinearVelocity
	-- Apenas o plano horizontal (ignora pulo/queda)
	local speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	local state: string
	if self.IsCrouching then
		-- Agachado a velocidade é baixa (CROUCH_CONFIG.WalkSpeed), então usamos um limiar
		-- de movimento próprio em vez dos limiares de andar/correr em pé.
		if speed > MOVE_MIN_SPEED then
			state = "CrouchWalk"
		else
			state = "CrouchIdle"
		end
	elseif speed > WALK_MAX_SPEED then
		state = "Run"
	elseif speed >= WALK_MIN_SPEED then
		state = "Walk"
	else
		state = "Idle"
	end

	self:PlayState(state)
	self:UpdateAnimationSpeed(state, speed)
end

-- Troca para a animação do estado, parando a anterior
function HumanoidController:PlayState(state: string)
	if self.CurrentState == state then
		return
	end

	local previous = self.CurrentState and self.Tracks[self.CurrentState]
	if previous then
		previous:Stop(0.15)
	end

	local track = self.Tracks[state]
	if track then
		track:Play(0.15)
	end

	self.CurrentState = state
end

-- Ajusta a velocidade de reprodução proporcional à velocidade da rootpart
function HumanoidController:UpdateAnimationSpeed(state: string, speed: number)
	local track = self.Tracks[state]
	if not track then
		return
	end

	if state == "Walk" then
		track:AdjustSpeed(speed / WALK_BASE_SPEED)
	elseif state == "Run" then
		track:AdjustSpeed(speed / RUN_BASE_SPEED)
	elseif state == "CrouchWalk" then
		track:AdjustSpeed(speed / CROUCH_CONFIG.WalkSpeed)
	else
		track:AdjustSpeed(1)
	end
end

-- Retorna a instância do Viewmodel (do ViewmodelController), se disponível.
function HumanoidController:GetViewmodel()
	local controller = self.GetController and self.GetController("ViewmodelController")
	return controller and controller:GetViewmodel()
end

-- Abaixa/levanta câmera e viewmodel suavemente conforme o estado de agachado.
-- O viewmodel segue a CFrame da câmera (que inclui o CameraOffset), então abaixar o
-- offset da câmera abaixa os dois juntos.
function HumanoidController:UpdateCrouchOffset(deltaTime: number)
	local viewmodel = self:GetViewmodel()
	if not viewmodel then
		return
	end

	-- Captura o offset base uma única vez (antes de começarmos a sobrescrevê-lo).
	if not self.BaseCameraOffset then
		self.BaseCameraOffset = viewmodel.CameraOffset or CFrame.new()
	end

	local target = self.IsCrouching and 1 or 0
	local alpha = 1 - math.exp(-CROUCH_CONFIG.TransitionSpeed * deltaTime)
	self.CrouchAmount += (target - self.CrouchAmount) * alpha
	if math.abs(self.CrouchAmount - target) < 0.001 then
		self.CrouchAmount = target
	end

	local dip = CFrame.new(0, -CROUCH_CONFIG.CameraDip * self.CrouchAmount, 0)
	viewmodel:SetCameraOffset(self.BaseCameraOffset * dip)
end

function HumanoidController:IsCrouchingState(): boolean
	return self.IsCrouching
end

function HumanoidController:GetCrouchWalkSpeed(): number
	return CROUCH_CONFIG.WalkSpeed
end

-- Liga/desliga o agachar. A WalkSpeed agachada é imposta aqui e também respeitada todo
-- frame pelo SprintController (que sobrescreve a WalkSpeed), para não ser anulada.
function HumanoidController:SetCrouching(enabled: boolean)
	if self.IsCrouching == enabled then
		return
	end
	self.IsCrouching = enabled

	local humanoid = self.Humanoid
	if humanoid then
		if enabled then
			humanoid.WalkSpeed = CROUCH_CONFIG.WalkSpeed
		else
			-- Volta à velocidade normal imediatamente; o SprintController reassume no próximo frame.
			humanoid.WalkSpeed = self.Overrides.WalkSpeed or DEFAULT_PROPERTIES.WalkSpeed
		end
	end

	if self.MobileCrouchButton then
		self.MobileCrouchButton.BackgroundColor3 = enabled
			and Color3.fromRGB(120, 180, 255)
			or Color3.fromRGB(40, 40, 40)
	end
end

function HumanoidController:ToggleCrouch()
	self:SetCrouching(not self.IsCrouching)
end

-- Configura os binds de agachar (alternar): tecla (PC), botão do controle (console) e
-- botão de toque (mobile). Chamado uma única vez no :Start.
function HumanoidController:SetupCrouchInput()
	if self.CrouchInputReady then
		return
	end
	self.CrouchInputReady = true

	local function onCrouchAction(_actionName: string, inputState: Enum.UserInputState)
		if inputState == Enum.UserInputState.Begin then
			self:ToggleCrouch()
		end
		return Enum.ContextActionResult.Pass
	end

	-- createTouchButton = false: criamos nosso próprio botão de toque posicionado em Scale.
	ContextActionService:BindAction(
		CROUCH_ACTION,
		onCrouchAction,
		false,
		CROUCH_CONFIG.KeyboardKey,
		CROUCH_CONFIG.GamepadKey
	)

	if UserInputService.TouchEnabled then
		self:CreateMobileCrouchButton()
	end
end

-- Cria o botão de agachar do mobile, posicionado (em Scale) um pouco acima do botão de pular.
function HumanoidController:CreateMobileCrouchButton()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "CrouchButtonGui"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.Parent = playerGui

	local button = Instance.new("TextButton")
	button.Name = "CrouchButton"
	button.AnchorPoint = Vector2.new(0.5, 0.5)
	button.Position = CROUCH_CONFIG.MobileButtonPosition
	button.Size = CROUCH_CONFIG.MobileButtonSize
	button.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
	button.BackgroundTransparency = 0.3
	button.Text = "▼"
	button.TextScaled = true
	button.TextColor3 = Color3.new(1, 1, 1)
	button.AutoButtonColor = false
	button.Parent = screenGui

	-- Mantém o botão quadrado (círculo com o UICorner) independente da resolução.
	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = 1
	aspect.Parent = button

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = button

	button.Activated:Connect(function()
		self:ToggleCrouch()
	end)

	-- Só aparece quando o dispositivo atual é mobile (toque), acompanhando trocas de input.
	local function updateVisibility()
		screenGui.Enabled = DeviceController:IsMobile()
	end
	updateVisibility()
	UserInputService.LastInputTypeChanged:Connect(updateVisibility)

	self.MobileCrouchButton = button
end

function HumanoidController:GetHumanoid(): Humanoid?
	return self.Humanoid
end

function HumanoidController:ApplyOverrides()
	local humanoid = self.Humanoid
	if not humanoid then
		return
	end

	for property, value in pairs(self.Overrides) do
		(humanoid :: any)[property] = value
	end
end

function HumanoidController:SetProperty(property: string, value: any)
	--print("Setting Humanoid property:", property, "to", value)
	self.Overrides[property] = value

	local humanoid = self.Humanoid
	if humanoid then
		(humanoid :: any)[property] = value
	end
end

function HumanoidController:ResetProperty(property: string)
	self.Overrides[property] = nil

	local humanoid = self.Humanoid
	if humanoid and DEFAULT_PROPERTIES[property] ~= nil then
		(humanoid :: any)[property] = DEFAULT_PROPERTIES[property]
	end
end

function HumanoidController:ResetAll()
	self.Overrides = {}

	local humanoid = self.Humanoid
	if not humanoid then
		return
	end

	for property, value in pairs(DEFAULT_PROPERTIES) do
		(humanoid :: any)[property] = value
	end
end

function HumanoidController:SetWalkSpeed(walkSpeed: number)
	self:SetProperty("WalkSpeed", walkSpeed)
end

function HumanoidController:SetJumpPower(jumpPower: number)
	self:SetProperty("UseJumpPower", true)
	self:SetProperty("JumpPower", jumpPower)
end

function HumanoidController:SetJumpHeight(jumpHeight: number)
	self:SetProperty("UseJumpPower", false)
	self:SetProperty("JumpHeight", jumpHeight)
end

function HumanoidController:SetAutoRotate(enabled: boolean)
	self:SetProperty("AutoRotate", enabled)
end

return HumanoidController
