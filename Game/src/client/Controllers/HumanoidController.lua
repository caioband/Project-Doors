--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer

local DEFAULT_PROPERTIES = {
	WalkSpeed = 8,
	JumpPower = 50,
	JumpHeight = 7.2,
	AutoRotate = true,
	UseJumpPower = true,
}

-- Ids de animação customizadas (preencher com os asset ids desejados)
local ANIMATION_IDS = {
	Idle = "rbxassetid://124346862153043",
	Walk = "rbxassetid://133908840566076",
	Run = "rbxassetid://136145008370352",
}

-- Velocidades de referência para escalar a velocidade de reprodução das animações
local WALK_BASE_SPEED = 8
local RUN_BASE_SPEED = 16

-- Limiares de velocidade para troca de animação
local WALK_MIN_SPEED = 7
local WALK_MAX_SPEED = 14

local HumanoidController = {}
HumanoidController.Humanoid = nil :: Humanoid?
HumanoidController.Animator = nil :: Animator?
HumanoidController.RootPart = nil :: BasePart?
HumanoidController.Tracks = {} :: { [string]: AnimationTrack }
HumanoidController.CurrentState = nil :: string?
HumanoidController.AnimationConnection = nil :: RBXScriptConnection?
HumanoidController.Overrides = {}

function HumanoidController:Start()
	local function onCharacterAdded(character: Model)
		local humanoid = character:WaitForChild("Humanoid") :: Humanoid
		self.Humanoid = humanoid
		self.RootPart = character:WaitForChild("HumanoidRootPart") :: BasePart

		self:DisableDefaultAnimations(character)
		self:SetupAnimations(humanoid)
		self:StartAnimationLoop()

		self:ApplyOverrides()
	end

	if LocalPlayer.Character then
		onCharacterAdded(LocalPlayer.Character)
	end

	LocalPlayer.CharacterAdded:Connect(onCharacterAdded)

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

	for name, id in pairs(ANIMATION_IDS) do
		local animation = Instance.new("Animation")
		animation.Name = name
		animation.AnimationId = id

		local track = (animator :: Animator):LoadAnimation(animation)
		track.Priority = Enum.AnimationPriority.Movement
		track.Looped = true
		self.Tracks[name] = track
	end
end

-- Inicia o loop que decide qual animação tocar com base na velocidade da rootpart
function HumanoidController:StartAnimationLoop()
	if self.AnimationConnection then
		self.AnimationConnection:Disconnect()
		self.AnimationConnection = nil
	end

	self.AnimationConnection = RunService.RenderStepped:Connect(function()
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
	if speed > WALK_MAX_SPEED then
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
	else
		track:AdjustSpeed(1)
	end
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
