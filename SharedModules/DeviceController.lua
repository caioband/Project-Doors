local UserInputService = game:GetService("UserInputService")

local DeviceController = {
	currentDevice = nil,
	started = false,
	lastInputConnection = nil,
}

function DeviceController:DetectDevice()
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return "Mobile"
	end

	if UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled then
		return "Console"
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