--!strict
-- HuntSensesController (client)
-- "Sentidos de perigo" quando uma IA esta CACANDO. O server (NPCService) avisa por
-- ReplicatedStorage.Comms.NPC.HuntState (npcModel, isHunting) quando um NPC entra/sai do modo caca.
-- Enquanto houver >= 1 cacador ativo, este controller:
--   * toca dois sons 2D em loop — Heartbeat e DeepBreathing — cujo VOLUME sobe conforme o cacador
--     MAIS PROXIMO se aproxima do jogador local;
--   * treme a camera, com a INTENSIDADE do tremor tambem subindo com a proximidade.
-- Suporta VARIOS cacadores ao mesmo tempo (usa a menor distancia entre eles). Quando nao ha mais
-- nenhum cacando, os sons e o tremor sao desligados (com um pequeno amortecimento para nao "pipocar").
--
-- Nao depende de quem e o alvo: cada cliente calcula a intensidade pela SUA propria distancia ao
-- cacador mais proximo. O modelo do NPC replica (server-autoritativo), entao usamos a posicao dele
-- direto do Workspace.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

-- Distancias (studs): intensidade vai de 0 (a >= FAR) ate 1 (a <= NEAR).
local FAR_DISTANCE = 70
local NEAR_DISTANCE = 6
-- Volumes maximos (na intensidade 1). Ajuste a gosto.
local HEARTBEAT_MAX_VOLUME = 1
local BREATHING_MAX_VOLUME = 0.7
-- Heartbeat acelera um pouco de perto (coracao disparado): playback speed de 1 (longe) a este valor.
local HEARTBEAT_MAX_SPEED = 1.6
-- Tremor de camera na intensidade 1: angulo maximo (rad), deslocamento maximo (studs) e frequencia.
local MAX_SHAKE_ANGLE = math.rad(3.5)
local MAX_SHAKE_OFFSET = 0.35
local SHAKE_FREQUENCY = 22
-- Amortecimento da intensidade (por segundo). Maior = converge mais rapido para o alvo.
local SMOOTH_SPEED = 6

local HEARTBEAT_ID = "rbxassetid://74422491240613"
local BREATHING_ID = "rbxassetid://118400948110390"

local HuntSensesController = {}

-- Modelos de NPC atualmente cacando (set: [Model] = true).
local activeHunters: { [Model]: boolean } = {}

local heartbeatSound: Sound
local breathingSound: Sound
local currentIntensity = 0
local shakeTime = 0

-- Cria um Sound 2D (em loop, mudo) parenteado ao SoundService (sem atenuacao espacial).
local function makeSound(id: string): Sound
	local sound = Instance.new("Sound")
	sound.SoundId = id
	sound.Looped = true
	sound.Volume = 0
	sound.Parent = SoundService
	return sound
end

-- Ha pelo menos um cacador ativo?
local function hasAnyHunter(): boolean
	for _ in pairs(activeHunters) do
		return true
	end
	return false
end

-- Menor distancia do jogador local a um cacador ativo (math.huge se nenhum valido). De quebra,
-- limpa modelos que ja sumiram (mapa descarregado sem o evento de saida).
local function nearestHunterDistance(originPos: Vector3): number
	local best = math.huge
	for model in pairs(activeHunters) do
		if not model.Parent then
			activeHunters[model] = nil
		else
			local ok, pivot = pcall(function()
				return model:GetPivot().Position
			end)
			if ok then
				local d = (pivot - originPos).Magnitude
				if d < best then
					best = d
				end
			end
		end
	end
	return best
end

function HuntSensesController:_onRender(dt: number)
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?

	-- Intensidade ALVO pela distancia do cacador mais proximo (0 se nao ha cacador / sem personagem).
	local targetIntensity = 0
	local anyHunter = hasAnyHunter()
	if root and anyHunter then
		local dist = nearestHunterDistance(root.Position)
		if dist < math.huge then
			targetIntensity = math.clamp((FAR_DISTANCE - dist) / (FAR_DISTANCE - NEAR_DISTANCE), 0, 1)
		end
	end

	-- Suaviza a intensidade atual em direcao ao alvo (evita saltos ao ligar/desligar/teleportar).
	currentIntensity += (targetIntensity - currentIntensity) * math.clamp(dt * SMOOTH_SPEED, 0, 1)
	if currentIntensity < 0.001 then
		currentIntensity = 0
	end

	-- Sons: tocam enquanto houver cacador; param quando nao ha nenhum E a intensidade ja zerou.
	if anyHunter then
		if not heartbeatSound.IsPlaying then
			heartbeatSound:Play()
		end
		if not breathingSound.IsPlaying then
			breathingSound:Play()
		end
	elseif currentIntensity == 0 then
		if heartbeatSound.IsPlaying then
			heartbeatSound:Stop()
		end
		if breathingSound.IsPlaying then
			breathingSound:Stop()
		end
	end
	heartbeatSound.Volume = currentIntensity * HEARTBEAT_MAX_VOLUME
	heartbeatSound.PlaybackSpeed = 1 + currentIntensity * (HEARTBEAT_MAX_SPEED - 1)
	breathingSound.Volume = currentIntensity * BREATHING_MAX_VOLUME

	-- Tremor de camera (aplicado DEPOIS do posicionamento da camera, prioridade Camera+1). Usa ruido
	-- Perlin em vez de random puro para um tremor continuo/organico. Nao acumula: a camera reposiciona
	-- todo frame antes desta etapa, entao so somamos o offset atual.
	if currentIntensity > 0.001 then
		shakeTime += dt
		local camera = workspace.CurrentCamera
		if camera then
			local amp = currentIntensity
			local n1 = math.noise(shakeTime * SHAKE_FREQUENCY, 0.0)
			local n2 = math.noise(0.0, shakeTime * SHAKE_FREQUENCY)
			local n3 = math.noise(shakeTime * SHAKE_FREQUENCY, shakeTime * SHAKE_FREQUENCY)
			local rotation = CFrame.Angles(
				n1 * MAX_SHAKE_ANGLE * amp,
				n2 * MAX_SHAKE_ANGLE * amp,
				n3 * MAX_SHAKE_ANGLE * amp
			)
			local offset = Vector3.new(n2, n1, 0) * (MAX_SHAKE_OFFSET * amp)
			camera.CFrame = camera.CFrame * CFrame.new(offset) * rotation
		end
	end
end

function HuntSensesController:Start()
	heartbeatSound = makeSound(HEARTBEAT_ID)
	breathingSound = makeSound(BREATHING_ID)

	-- Fia o remote de forma assincrona: WaitForChild pode ceder ate o server criar Comms.NPC.HuntState;
	-- nao queremos bloquear o loop de Start dos Controllers por causa disso.
	task.spawn(function()
		local comms = ReplicatedStorage:WaitForChild("Comms")
		local npc = comms:WaitForChild("NPC")
		local huntState = npc:WaitForChild("HuntState") :: RemoteEvent
		huntState.OnClientEvent:Connect(function(model: Model, isHunting: boolean)
			if typeof(model) ~= "Instance" then
				return
			end
			if isHunting then
				activeHunters[model] = true
			else
				activeHunters[model] = nil
			end
		end)
	end)

	-- Prioridade Camera+1: roda depois que a camera se posiciona, para o tremor nao ser sobrescrito.
	RunService:BindToRenderStep("HuntSenses", Enum.RenderPriority.Camera.Value + 1, function(dt)
		self:_onRender(dt)
	end)

	print("✓ HuntSensesController initialized")
end

return HuntSensesController
