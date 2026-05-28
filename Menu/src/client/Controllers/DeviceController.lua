local UserInputService = game:GetService("UserInputService")

local DeviceController = {}

function DeviceController:DetectDevice()
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return "Mobile"
	end

	if UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled then
		return "Console"
	end

	return "PC"
end

function DeviceController:GetDevice()
	if not self.currentDevice then
		self.currentDevice = self:DetectDevice()
	end

	return self.currentDevice
end

function DeviceController:IsPC()
	return self:GetDevice() == "PC"
end

function DeviceController:Start()
	self.currentDevice = self:DetectDevice()
end

return DeviceController