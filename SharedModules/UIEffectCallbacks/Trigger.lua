local HoverTrigger = {
	Name = "Hover",
	AttributeName = "Callback",
}

local EVENT_NAMES = {
	"MouseEnter",
	"MouseLeave",
	"MouseButton1Down",
	"MouseButton1Up",
	"Activated",
}

local callbackCache = {}

local function resolveCallbackModule(callbackName)
	if callbackCache[callbackName] ~= nil then
		return callbackCache[callbackName] or nil
	end

	local callbackModule = script.Parent:FindFirstChild(callbackName)
	if not callbackModule or not callbackModule:IsA("ModuleScript") then
		callbackCache[callbackName] = false
		return nil
	end

	local ok, result = pcall(require, callbackModule)
	if not ok then
		warn(string.format("[UIEffectCallbacks] Failed to load callback %s: %s", callbackName, tostring(result)))
		callbackCache[callbackName] = false
		return nil
	end

	callbackCache[callbackName] = result
	return result
end

local function resolveCallback(button)
	local callbackName = button:GetAttribute(HoverTrigger.AttributeName)
	if type(callbackName) ~= "string" or callbackName == "" then
		return nil, nil
	end

	return resolveCallbackModule(callbackName), callbackName
end

local function dispatch(button, eventName, ...)
	local callbackEntry, callbackName = resolveCallback(button)
	if callbackEntry == nil then
		return
	end

	if type(callbackEntry) == "function" then
		callbackEntry(button, eventName, ...)
		return
	end

	if type(callbackEntry) ~= "table" then
		warn(string.format("[UIEffectCallbacks] Callback %s is invalid", tostring(callbackName)))
		return
	end

	local handler = callbackEntry[eventName] or callbackEntry.Default
	if type(handler) == "function" then
		handler(button, ...)
	end
end

function HoverTrigger.Bind(button)
	local connections = {}

	for _, eventName in ipairs(EVENT_NAMES) do
		table.insert(connections, button[eventName]:Connect(function(...)
			dispatch(button, eventName, ...)
		end))
	end

	return connections
end

return HoverTrigger