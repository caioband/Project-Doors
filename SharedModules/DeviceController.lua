local UserInputService = game:GetService("UserInputService")

local DeviceController = {
	currentDevice = nil,
	started = false,
	lastInputConnection = nil,
}

function DeviceController:DetectDevice()
	-- Classifica pelo ULTIMO input usado, e nao apenas pelo que esta conectado. Isso resolve
	-- o caso de teclado + controle conectados ao mesmo tempo: com a deteccao antiga, ter o
	-- teclado conectado forcava "PC" e o slot mostrava o bind de teclado mesmo jogando no
	-- controle. Prioridade efetiva: o que o player acabou de usar (Toque/Gamepad/Teclado-Mouse).
	local lastInput = UserInputService:GetLastInputType()

	if lastInput == Enum.UserInputType.Touch then
		return "Mobile"
	elseif string.match(lastInput.Name, "^Gamepad") then
		return "Console"
	elseif lastInput == Enum.UserInputType.Keyboard
		or lastInput == Enum.UserInputType.MouseButton1
		or lastInput == Enum.UserInputType.MouseButton2
		or lastInput == Enum.UserInputType.MouseButton3
		or lastInput == Enum.UserInputType.MouseMovement
		or lastInput == Enum.UserInputType.MouseWheel then
		return "PC"
	end

	-- Fallback por capacidade (ex.: antes do primeiro input). Mantem a prioridade Gamepad > teclado.
	if UserInputService.GamepadEnabled then
		return "Console"
	end

	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return "Mobile"
	end

	return "PC"
end

function DeviceController:RefreshDevice()
	self.currentDevice = self:DetectDevice()
	return self.currentDevice
end

function DeviceController:GetDevice()
	if not self.currentDevice then
		self:Start()
	end

	return self.currentDevice
end

function DeviceController:IsPC()
	return self:GetDevice() == "PC"
end

function DeviceController:IsMobile()
	return self:GetDevice() == "Mobile"
end

function DeviceController:IsConsole()
	return self:GetDevice() == "Console"
end

function DeviceController:Start()
	if self.started then
		return self.currentDevice
	end

	self.started = true
	self:RefreshDevice()

	self.lastInputConnection = UserInputService.LastInputTypeChanged:Connect(function()
		self:RefreshDevice()
	end)

	return self.currentDevice
end

DeviceController:Start()

return DeviceController