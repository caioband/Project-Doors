--!strict
-- AudioListenerController (client)
-- Cria um AudioListener na Head do personagem local assim que ele carrega, para que ESTE cliente
-- ouca os AudioEmitters do mundo (ex.: os RingEmitter dos telefones do Office) a partir da posicao
-- da cabeca do personagem.
--
-- Cadeia do lado ouvinte:
--   AudioListener (na Head) --Wire--> AudioDeviceOutput (alto-falantes do jogador)
-- O AudioInteractionGroup do listener deve casar com o dos AudioEmitters que se quer ouvir; aqui e
-- "General" (mesmo grupo dos RingEmitter dos telefones).

local Players = game:GetService("Players")

local LocalPlayer = Players.LocalPlayer

-- Grupo de interacao de audio: o listener so capta emitters no mesmo grupo.
local INTERACTION_GROUP = "General"
-- Nome do AudioListener criado na Head (usado para evitar duplicar em recargas/respawn).
local LISTENER_NAME = "CharacterAudioListener"

local AudioListenerController = {}

-- Monta o AudioListener + AudioDeviceOutput + Wire dentro da Head do personagem.
function AudioListenerController:_setupListener(character: Model)
	local head = character:WaitForChild("Head", 10) :: BasePart?
	if not head or not character.Parent then
		return
	end

	-- Ja existe (ex.: chamado mais de uma vez para o mesmo personagem): nao duplica.
	if head:FindFirstChild(LISTENER_NAME) then
		return
	end

	-- O AudioListener "ouve" a partir da posicao do seu pai (a Head).
	local listener = Instance.new("AudioListener")
	listener.Name = LISTENER_NAME
	listener.AudioInteractionGroup = INTERACTION_GROUP

	-- Saida de audio do dispositivo (alto-falantes/fones do jogador).
	local output = Instance.new("AudioDeviceOutput")
	output.Parent = listener

	-- Liga o que o listener capta (Output) a entrada da saida de audio (Input).
	local wire = Instance.new("Wire")
	wire.SourceInstance = listener
	wire.SourceName = "Output"
	wire.TargetInstance = output
	wire.TargetName = "Input"
	wire.Parent = output

	listener.Parent = head
end

function AudioListenerController:Start()
	local function onCharacterAdded(character: Model)
		self:_setupListener(character)
	end

	if LocalPlayer.Character then
		task.spawn(onCharacterAdded, LocalPlayer.Character :: Model)
	end
	LocalPlayer.CharacterAdded:Connect(onCharacterAdded)

	print("✓ AudioListenerController initialized")
end

return AudioListenerController
