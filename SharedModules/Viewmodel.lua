--!strict

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ReplicatedFirst = game:GetService("ReplicatedFirst")

local Preloader = require(ReplicatedFirst:WaitForChild("SharedModulesFirst"):WaitForChild("Preloader"))

local Viewmodel = {}
Viewmodel.__index = Viewmodel

export type ViewmodelConfig = {
	EnableHeadBob: boolean?,
	EnableCameraSway: boolean?,
	BaseWalkSpeed: number?,
	-- Velocidade na qual o FOV atinge o SprintFOV (usada para o FOV dinamico).
	MaxWalkSpeed: number?,
	HeadBobSpeed: number?,
	HeadBobIntensity: number?,
	HeadBobRotationIntensity: number?,
	HeadBobLeanIntensity: number?,
	HeadBobMaxLeanSide: number?,
	HeadBobMaxLeanForward: number?,
	HeadBobLeanDebounce: number?,
	HeadBobIdleSpeed: number?,
	HeadBobIdleIntensity: number?,
	SwayIntensity: number?,
	DefaultFOV: number?,
	SprintFOV: number?,
	FOVTransitionSpeed: number?,
	-- Offset estático aplicado à câmera (primeira pessoa) em relação à orientação dela.
	-- Aceita CFrame ou Vector3 (posição). Ver :SetCameraOffset.
	CameraOffset: (CFrame | Vector3)?,
}

local DEFAULT_CONFIG: ViewmodelConfig = {
	EnableHeadBob = true,
	EnableCameraSway = true,
	BaseWalkSpeed = 16,
	MaxWalkSpeed = 20,
	HeadBobSpeed = 10,
	HeadBobIntensity = 0.05,
	HeadBobRotationIntensity = 0.01,
	HeadBobLeanIntensity = 0.04,
	HeadBobMaxLeanSide = 0.06,
	HeadBobMaxLeanForward = 0.04,
	HeadBobLeanDebounce = 0.15,
	HeadBobIdleSpeed = 1.5,
	HeadBobIdleIntensity = 0.008,
	SwayIntensity = 0.02,
	DefaultFOV = 70,
	SprintFOV = 80,
	FOVTransitionSpeed = 5,
	CameraOffset = CFrame.new(),
}

function Viewmodel.new(config: ViewmodelConfig?)
	local self = setmetatable({}, Viewmodel)

	self.Config = config or DEFAULT_CONFIG
	for key, value in pairs(DEFAULT_CONFIG) do
		if self.Config[key] == nil then
			self.Config[key] = value
		end
	end

	self.Player = Players.LocalPlayer
	self.Camera = workspace.CurrentCamera
	self.Character = nil
	self.Humanoid = nil
	self.HumanoidRootPart = nil

	-- Modelo de viewmodel clonado e anexado à câmera (criado em :CloneViewmodel)
	self.ViewmodelModel = nil
	-- Offset aplicado à root do viewmodel em relação à câmera (ver :SetViewmodelOffset)
	self.ViewmodelOffset = CFrame.new()
	-- Offset estático aplicado à câmera em relação à orientação dela (ver :SetCameraOffset).
	-- Inicializado a partir da config (CameraOffset), aceitando CFrame ou Vector3.
	self.CameraOffset = CFrame.new()
	self:SetCameraOffset(self.Config.CameraOffset)

	self.IsRunning = false
	self.IsPaused = false
	self.FreeMouse = false
	self.BaseWalkSpeed = 16
	self.CurrentBobTime = 0
	self.IdleBobTime = 0
	self.CurrentFOV = self.Config.DefaultFOV
	self.SwayRotation = Vector3.new(0, 0, 0)
	self.LeanRotation = Vector3.new(0, 0, 0)
	self.PrevForwardSpeed = 0
	self.PrevStrafeSign = 0
	self.PrevForwardSign = 0
	self.LeanDebounceTimer = 0

	self.Connections = {}

	return self
end

function Viewmodel:Start()
	self:_setupCharacter(self.Player.Character or self.Player.CharacterAdded:Wait())

	table.insert(self.Connections, self.Player.CharacterAdded:Connect(function(character)
		self:_setupCharacter(character)
	end))

	self:_bindRenderStep()
end

-- Liga o loop de render que atualiza câmera/viewmodel todo frame.
function Viewmodel:_bindRenderStep()
	RunService:BindToRenderStep(
		"ViewmodelUpdate",
		Enum.RenderPriority.Camera.Value + 1,
		function(deltaTime)
			self:_update(deltaTime)
		end
	)
end

function Viewmodel:_setupCharacter(character: Model)
	self.Character = character
	self.Humanoid = character:WaitForChild("Humanoid") :: Humanoid
	self.HumanoidRootPart = character:WaitForChild("HumanoidRootPart") :: BasePart
	self.BaseWalkSpeed = self.Config.BaseWalkSpeed :: number

	-- Force first person
	self.Humanoid.CameraOffset = Vector3.new(0, 0, 0)
	self.Camera.CameraType = Enum.CameraType.Custom

	-- Hide character parts for first person
	for _, part in ipairs(character:GetDescendants()) do
		if part:IsA("BasePart") and part.Name ~= "Head" then
			part.LocalTransparencyModifier = 1
		end
	end
end

function Viewmodel:_update(deltaTime: number)
	if not self.Character or not self.Humanoid or not self.HumanoidRootPart then
		return
	end

	-- A câmera padrão do Roblox força LockCenter todo frame em primeira pessoa,
	-- então reforçamos o mouse livre aqui para não ser sobrescrito.
	if self.FreeMouse then
		if UserInputService.MouseBehavior ~= Enum.MouseBehavior.Default then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		end
	end

	-- Calculate movement velocity (horizontal only, so falling/jumping doesn't spike the bob)
	local velocity = self.HumanoidRootPart.AssemblyLinearVelocity
	local horizontalVelocity = Vector3.new(velocity.X, 0, velocity.Z)
	local speed = horizontalVelocity.Magnitude

	-- Determine running state from the Humanoid's WalkSpeed
	self.IsRunning = self.Humanoid.WalkSpeed > self.BaseWalkSpeed + 0.01

	-- Velocity in the character's local space + forward acceleration.
	-- The forward/back lean reacts to acceleration (a transient dip when you start/stop)
	-- instead of steady velocity, so it never holds a sustained pitch that fights aim.
	local localVel = self.HumanoidRootPart.CFrame:VectorToObjectSpace(horizontalVelocity)
	local forwardSpeed = -localVel.Z -- +Z is backwards in Roblox, so forward = -Z
	local forwardAccel = (forwardSpeed - self.PrevForwardSpeed) / math.max(deltaTime, 1e-4)
	self.PrevForwardSpeed = forwardSpeed

	-- Debounce against lean-pumping: if the player reverses movement direction (on either
	-- axis) faster than HeadBobLeanDebounce, refuse to write a new lean and let it decay back
	-- to the original orientation. Stops them from spamming inputs to creep the camera around.
	local strafeSign = math.abs(localVel.X) > 1 and math.sign(localVel.X) or 0
	local forwardSign = math.abs(forwardSpeed) > 1 and math.sign(forwardSpeed) or 0
	local reversed = (strafeSign ~= 0 and self.PrevStrafeSign ~= 0 and strafeSign ~= self.PrevStrafeSign)
		or (forwardSign ~= 0 and self.PrevForwardSign ~= 0 and forwardSign ~= self.PrevForwardSign)

	self.LeanDebounceTimer = math.max(0, self.LeanDebounceTimer - deltaTime)

	local suppressLean = false
	if reversed then
		-- A reversal within the debounce window means they're flip-flopping: lock the lean.
		if self.LeanDebounceTimer > 0 then
			suppressLean = true
		end
		self.LeanDebounceTimer = self.Config.HeadBobLeanDebounce :: number
	end

	if strafeSign ~= 0 then
		self.PrevStrafeSign = strafeSign
	end
	if forwardSign ~= 0 then
		self.PrevForwardSign = forwardSign
	end

	local bobOffset = Vector3.new(0, 0, 0)
	local bobRotation = Vector3.new(0, 0, 0)
	local targetLean = Vector3.new(0, 0, 0)

	-- Head bob
	if self.Config.EnableHeadBob then
		local speedRatio = speed / math.max(self.BaseWalkSpeed, 1)

		if speed < 0.5 then
			-- Idle: subtle breathing bob when the player is essentially still
			self.IdleBobTime += deltaTime * (self.Config.HeadBobIdleSpeed :: number)
			self.CurrentBobTime *= 0.9
			bobOffset = Vector3.new(0, math.sin(self.IdleBobTime) * (self.Config.HeadBobIdleIntensity :: number), 0)
		else
			local dynSpeed = (self.Config.HeadBobSpeed :: number) * speedRatio
			local dynIntensity = (self.Config.HeadBobIntensity :: number) * speedRatio
			local dynRotIntensity = (self.Config.HeadBobRotationIntensity :: number) * speedRatio

			if self.IsRunning then
				dynIntensity *= 1.5
				dynRotIntensity *= 1.5
			end

			self.CurrentBobTime += deltaTime * dynSpeed

			local bobX = math.sin(self.CurrentBobTime) * dynIntensity
			local bobY = math.abs(math.sin(self.CurrentBobTime * 2)) * dynIntensity
			bobOffset = Vector3.new(bobX, bobY, 0)

			-- Tilt the camera in sync with the bob cycle (head roll + slight pitch)
			bobRotation = Vector3.new(
				math.sin(self.CurrentBobTime * 2) * dynRotIntensity,
				0,
				math.sin(self.CurrentBobTime) * dynRotIntensity
			)

			-- Lean the camera toward the direction the player is moving (unless debounced).
			if not suppressLean then
				local leanIntensity = self.Config.HeadBobLeanIntensity :: number
				local maxLeanForward = self.Config.HeadBobMaxLeanForward :: number
				local maxLeanSide = self.Config.HeadBobMaxLeanSide :: number

				-- Pitch (frente/trás): a transient dip driven by forward acceleration, so it
				-- returns to neutral while walking steadily (no sustained pitch that fights aim).
				local pitchLean = math.clamp(-forwardAccel * leanIntensity * 0.02, -maxLeanForward, maxLeanForward)

				-- Roll (direita/esquerda): bank into the strafe direction.
				local strafeRatio = math.clamp(localVel.X / math.max(self.BaseWalkSpeed, 1), -1, 1)
				local rollLean = math.clamp(-strafeRatio * leanIntensity, -maxLeanSide, maxLeanSide)

				targetLean = Vector3.new(pitchLean, 0, rollLean)
			end
		end
	end

	-- Smoothly ease the lean toward its target so it builds/releases gently
	local leanAlpha = 1 - math.exp(-8 * deltaTime)
	self.LeanRotation = self.LeanRotation:Lerp(targetLean, leanAlpha)
	bobRotation += self.LeanRotation

	-- Camera sway based on mouse movement (desativado enquanto o mouse estiver livre,
	-- já que o cursor não está travado no centro e o delta não representa movimento de câmera)
	-- O sway depende de GetMouseDelta, que em telas de toque reporta o movimento do dedo
	-- (inclusive do thumbstick). So aplicamos quando ha um mouse real.
	local swayRotation = Vector3.new(0, 0, 0)
	if self.Config.EnableCameraSway and not self.FreeMouse and UserInputService.MouseEnabled then
		local mouseDelta = UserInputService:GetMouseDelta()
		local intensity = self.Config.SwayIntensity

		local targetSway = Vector3.new(
			math.clamp(-mouseDelta.Y * intensity, -0.08, 0.08),
			math.clamp(-mouseDelta.X * intensity, -0.08, 0.08),
			math.clamp(mouseDelta.X * intensity * 0.5, -0.04, 0.04)
		)

		local alpha = 1 - math.exp(-12 * deltaTime)
		self.SwayRotation = self.SwayRotation:Lerp(targetSway, alpha)
		swayRotation = self.SwayRotation
	end

	-- Apply head bob (position + rotation) and camera sway directly to the camera CFrame.
	-- This is computed fresh on top of the base camera CFrame every frame, so it can't get
	-- "stuck" by Humanoid.CameraOffset being reset on humanoid state changes (e.g. sprint toggles).
	local bobCFrame = CFrame.new(bobOffset) * CFrame.Angles(bobRotation.X, bobRotation.Y, bobRotation.Z)
	local swayCFrame = CFrame.Angles(swayRotation.X, swayRotation.Y, swayRotation.Z)
	-- O CameraOffset (estático, vindo da config) é aplicado por último, em espaço local da câmera,
	-- depois do head bob/sway. O viewmodel segue self.Camera.CFrame, então herda esse offset.
	self.Camera.CFrame = self.Camera.CFrame * bobCFrame * swayCFrame * self.CameraOffset

	-- Acompanha o viewmodel clonado com a câmera e aplica o sway (da config) ao modelo.
	-- A câmera já inclui bob/sway, então o modelo herda esse movimento por seguir a câmera;
	-- o swayCFrame extra dá ao viewmodel o balanço característico de arma vindo de SwayIntensity.
	if self.ViewmodelModel then
		local root = self.ViewmodelModel.PrimaryPart
		if root then
			-- Compensa o FOV: ao mudar o FOV (ex.: sprint), o viewmodel pareceria encolher e
			-- se afastar. Para manter o mesmo tamanho/posição aparente na tela, a distância do
			-- modelo até a câmera precisa escalar por tan(FOVbase/2) / tan(FOVatual/2).
			local baseFOV = self.Config.DefaultFOV :: number
			local fovScale = math.tan(math.rad(baseFOV / 2)) / math.tan(math.rad(self.CurrentFOV / 2))

			-- Profundidade do modelo à frente da root (em studs). Como a root é colada à câmera,
			-- essa é a distância da "ponta" do viewmodel até o olho; é ela que precisa escalar.
			-- (forward = -Z no espaço da root.)
			local center = self.ViewmodelModel:GetBoundingBox().Position
			local depth = -(root.CFrame:PointToObjectSpace(center).Z)

			-- Reposiciona a root para que (offset lateral + profundidade) escale por fovScale:
			--   pos = offsetLateral * fovScale  +  recuo ao longo do forward p/ ajustar a profundidade.
			local pos = self.ViewmodelOffset.Position * fovScale
				+ Vector3.new(0, 0, depth * (1 - fovScale))
			local fovOffset = self.ViewmodelOffset.Rotation + pos

			root.CFrame = self.Camera.CFrame * swayCFrame * fovOffset
		end
	end

	-- FOV dinamico: interpola entre DefaultFOV (na velocidade base) e SprintFOV (na velocidade
	-- maxima), acompanhando a velocidade real do player. Como a WalkSpeed varia com o quanto o
	-- thumbstick esta esticado (mobile/console), o FOV passa a acompanhar essa variacao.
	local fovRange = math.max((self.Config.MaxWalkSpeed :: number) - self.BaseWalkSpeed, 1e-3)
	local fovRatio = math.clamp((speed - self.BaseWalkSpeed) / fovRange, 0, 1)
	local targetFOV = self.Config.DefaultFOV + (self.Config.SprintFOV - self.Config.DefaultFOV) * fovRatio
	self.CurrentFOV = self.CurrentFOV + (targetFOV - self.CurrentFOV) * self.Config.FOVTransitionSpeed * deltaTime
	self.Camera.FieldOfView = self.CurrentFOV
end

function Viewmodel:SetFirstPerson(enabled: boolean)
	if not self.Player then return end

	if enabled then
		self.Player.CameraMaxZoomDistance = 0.5
		self.Player.CameraMinZoomDistance = 0.5

		-- So travamos o mouse quando existe um mouse de fato. Em dispositivos de toque,
		-- forcar LockCenter faz a camera padrao entrar em modo mouse-look e interpretar o
		-- arrasto do thumbstick como movimento de mouse, girando a camera no eixo do movimento
		-- (frente = olha pra cima, tras = pra baixo) ate ficar olhando pro teto/chao.
		if UserInputService.MouseEnabled then
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
			UserInputService.MouseIconEnabled = false
		end
	else
		self.Player.CameraMaxZoomDistance = 128
		self.Player.CameraMinZoomDistance = 0.5

		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
	end
end

function Viewmodel:SetFreeMouse(enabled: boolean)
	self.FreeMouse = enabled

	if enabled then
		-- Libera o mouse e restaura o ícone/cursor padrão
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
	else
		-- Volta a travar o mouse no centro (primeira pessoa), apenas quando ha um mouse real.
		-- Em telas de toque manter MouseBehavior.Default evita o mouse-look fantasma do thumbstick.
		if UserInputService.MouseEnabled then
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
			UserInputService.MouseIconEnabled = false
		end
	end
end

function Viewmodel:ToggleFreeMouse(): boolean
	self:SetFreeMouse(not self.FreeMouse)
	return self.FreeMouse
end

function Viewmodel:SetConfig(newConfig: ViewmodelConfig)
	for key, value in pairs(newConfig) do
		self.Config[key] = value
	end
end

-- Clona o modelo de viewmodel de ReplicatedStorage.Assets.Models.Viewmodel.Viewmodel,
-- posiciona a root (PrimaryPart) na CFrame da câmera atual e anexa o modelo à câmera.
function Viewmodel:CloneViewmodel(): Model?
	-- Garante que não exista um viewmodel anterior pendurado na câmera
	self:DestroyViewmodel()

	local template = ReplicatedStorage
		:WaitForChild("Assets")
		:WaitForChild("Models")
		:WaitForChild("Viewmodel")
		:WaitForChild("Viewmodel")

	local clone = template:Clone()

	-- Posiciona a root do viewmodel exatamente na CFrame da câmera atual.
	local root = clone.PrimaryPart or clone:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		root.CFrame = self.Camera.CFrame
	end

	clone.Parent = self.Camera
	self.ViewmodelModel = clone

	return clone
end

-- Destrói um dos braços (ex.: "LeftArm" / "RightArm") do viewmodel atual.
function Viewmodel:DestroyArm(armName: string)
	if not self.ViewmodelModel then
		warn("Viewmodel:DestroyArm chamado sem um viewmodel ativo (use :CloneViewmodel primeiro)")
		return
	end

	local arm = self.ViewmodelModel:FindFirstChild(armName)
	if not arm then
		warn(("Viewmodel:DestroyArm: braço '%s' não encontrado no viewmodel"):format(armName))
		return
	end

	arm:Destroy()
end

-- Clona um modelo/peça de item, posiciona-o no AttachPart do braço direito e o
-- parenteia ao próprio ViewmodelModel. Se o AttachPart tiver um Weld pré-configurado
-- com o mesmo nome do item (ex.: "Flashlight"), liga esse Weld ao clone para que o item
-- acompanhe a animação do braço (o C0 do Weld define o encaixe relativo ao AttachPart).
-- Retorna o clone.
function Viewmodel:AttachItemToRightArm(template: Instance): Instance?
	if not self.ViewmodelModel then
		warn("Viewmodel:AttachItemToRightArm chamado sem um viewmodel ativo (use :CloneViewmodel primeiro)")
		return nil
	end

	local rightArm = self.ViewmodelModel:FindFirstChild("RightArm")
	if not rightArm then
		warn("Viewmodel:AttachItemToRightArm: 'RightArm' não encontrado no viewmodel")
		return nil
	end

	-- O RightArm tem um Part e um Motor6D ambos chamados "AttachPart"; queremos a peça.
	local attachPart: BasePart? = nil
	for _, child in ipairs(rightArm:GetChildren()) do
		if child.Name == "AttachPart" and child:IsA("BasePart") then
			attachPart = child
			break
		end
	end

	if not attachPart then
		warn("Viewmodel:AttachItemToRightArm: 'AttachPart' (BasePart) não encontrado no RightArm")
		return nil
	end

	local clone = template:Clone()

	-- Posiciona o item na CFrame do AttachPart (o Weld, se houver, refina o encaixe).
	if clone:IsA("Model") then
		clone:PivotTo(attachPart.CFrame)
	elseif clone:IsA("BasePart") then
		clone.CFrame = attachPart.CFrame
	end

	clone.Parent = self.ViewmodelModel

	-- Liga o Weld pré-configurado (mesmo nome do item) ao clone, se existir.
	local weld = attachPart:FindFirstChild(clone.Name)
	if weld and weld:IsA("Weld") then
		weld.Part1 = if clone:IsA("BasePart") then clone else clone.PrimaryPart
	end

	return clone
end

-- Clona uma pasta específica de animações de ReplicatedStorage.Assets.Anims.Viewmodel
-- (ex.: "Flashlight") e a coloca dentro da pasta "Anims" do viewmodel atual do player.
function Viewmodel:CloneAnimsFolder(folderName: string): Folder?
	if not self.ViewmodelModel then
		warn("Viewmodel:CloneAnimsFolder chamado sem um viewmodel ativo (use :CloneViewmodel primeiro)")
		return nil
	end

	local sourceFolder = ReplicatedStorage
		:WaitForChild("Assets")
		:WaitForChild("Anims")
		:WaitForChild("Viewmodel")
		:FindFirstChild(folderName)

	if not sourceFolder then
		warn(("Viewmodel:CloneAnimsFolder: pasta de animações '%s' não encontrada"):format(folderName))
		return nil
	end

	local destFolder = self.ViewmodelModel:FindFirstChild("Anims")
	if not destFolder then
		warn("Viewmodel:CloneAnimsFolder: pasta 'Anims' não encontrada no viewmodel atual")
		return nil
	end

	local clone = sourceFolder:Clone()
	clone.Parent = destFolder

	return clone
end

-- Pré-carrega (via Preloader) todas as animações presentes na pasta "Anims"
-- do viewmodel atual do player.
function Viewmodel:LoadViewmodelAnims()
	if not self.ViewmodelModel then
		warn("Viewmodel:LoadViewmodelAnims chamado sem um viewmodel ativo (use :CloneViewmodel primeiro)")
		return
	end

	local animsFolder = self.ViewmodelModel:FindFirstChild("Anims")
	if not animsFolder then
		warn("Viewmodel:LoadViewmodelAnims: pasta 'Anims' não encontrada no viewmodel atual")
		return
	end

	local animations = {}
	for _, descendant in ipairs(animsFolder:GetDescendants()) do
		if descendant:IsA("Animation") then
			table.insert(animations, descendant)
		end
	end

	if #animations == 0 then
		return
	end

	local preloader = Preloader.new()
	preloader:SetAssetsToPreload(animations)
	preloader:PreloadAssets()
	preloader:Destroy()
end

-- Pré-carrega (via Preloader) as animações de uma pasta de origem em
-- ReplicatedStorage.Assets.Anims.Viewmodel (ex.: "Flashlight"), sem precisar de um
-- viewmodel clonado. Útil para adiantar o download das animações de um item assim
-- que ele é adquirido, deixando-o pronto para o primeiro equip.
-- Atenção: yield (ContentProvider:PreloadAsync), chame em task.spawn se não quiser bloquear.
function Viewmodel:PreloadAnimsFolder(folderName: string)
	local sourceFolder = ReplicatedStorage
		:WaitForChild("Assets")
		:WaitForChild("Anims")
		:WaitForChild("Viewmodel")
		:FindFirstChild(folderName)

	if not sourceFolder then
		warn(("Viewmodel:PreloadAnimsFolder: pasta de animações '%s' não encontrada"):format(folderName))
		return
	end

	local animations = {}
	for _, descendant in ipairs(sourceFolder:GetDescendants()) do
		if descendant:IsA("Animation") then
			table.insert(animations, descendant)
		end
	end

	if #animations == 0 then
		return
	end

	local preloader = Preloader.new()
	preloader:SetAssetsToPreload(animations)
	preloader:PreloadAssets()
	preloader:Destroy()
end

-- Define o offset da root do viewmodel atual em relação à câmera.
-- Aceita uma CFrame, ou um Vector3/posição que é convertida para CFrame.new(...).
-- O offset é aplicado todo frame no :_update, então vale para o viewmodel atual e os próximos.
function Viewmodel:SetViewmodelOffset(offset: CFrame | Vector3)
	if typeof(offset) == "Vector3" then
		self.ViewmodelOffset = CFrame.new(offset)
	else
		self.ViewmodelOffset = offset
	end
end

-- Define o offset estático da câmera em relação à orientação dela (primeira pessoa).
-- Aceita uma CFrame, ou um Vector3/posição convertida para CFrame.new(...). Valores invalidos/nil
-- viram CFrame.new() (sem offset). Aplicado todo frame no :_update, após o head bob/sway.
function Viewmodel:SetCameraOffset(offset: (CFrame | Vector3)?)
	if typeof(offset) == "Vector3" then
		self.CameraOffset = CFrame.new(offset)
	elseif typeof(offset) == "CFrame" then
		self.CameraOffset = offset
	else
		self.CameraOffset = CFrame.new()
	end
end

-- Destrói o modelo de viewmodel que foi clonado e anexado à câmera do player.
function Viewmodel:DestroyViewmodel()
	if self.ViewmodelModel then
		self.ViewmodelModel:Destroy()
		self.ViewmodelModel = nil
	end
end

-- Pausa o viewmodel: para o loop de render (deixando a câmera livre para ser controlada
-- por outro sistema, ex.: votação) e esconde o modelo clonado e quaisquer itens anexados
-- (filhos do modelo) tirando-o da câmera. Guarda o estado para restaurar em :Resume.
-- O FOV volta ao padrão para a câmera externa não herdar um FOV de sprint, por exemplo.
function Viewmodel:Pause()
	if self.IsPaused then
		return
	end
	self.IsPaused = true

	RunService:UnbindFromRenderStep("ViewmodelUpdate")

	if self.ViewmodelModel then
		self._pausedParent = self.ViewmodelModel.Parent
		self.ViewmodelModel.Parent = nil
	end

	if self.Camera then
		self.Camera.FieldOfView = self.Config.DefaultFOV :: number
	end
end

-- Retoma o viewmodel após um :Pause: reexibe o modelo (devolvendo-o à câmera) e religa o
-- loop de render. A câmera deve estar de volta ao tipo Custom antes de chamar isto.
function Viewmodel:Resume()
	if not self.IsPaused then
		return
	end
	self.IsPaused = false

	if self.ViewmodelModel then
		self.ViewmodelModel.Parent = self._pausedParent or self.Camera
		self._pausedParent = nil
	end

	self.CurrentFOV = self.Config.DefaultFOV :: number
	self:_bindRenderStep()
end

function Viewmodel:Destroy()
	self:DestroyViewmodel()

	for _, connection in ipairs(self.Connections) do
		connection:Disconnect()
	end

	self.Connections = {}

	-- Reset camera
	if self.Camera then
		RunService:UnbindFromRenderStep("ViewmodelUpdate")
		self.Camera.CameraType = Enum.CameraType.Custom
		self.Camera.FieldOfView = 70
	end

	-- Restore character visibility
	if self.Character then
		for _, part in ipairs(self.Character:GetDescendants()) do
			if part:IsA("BasePart") then
				part.LocalTransparencyModifier = 0
			end
		end
	end

	if self.Player then
		self.Player.CameraMaxZoomDistance = 128
		self.Player.CameraMinZoomDistance = 0.5

		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
	end
end

return Viewmodel
