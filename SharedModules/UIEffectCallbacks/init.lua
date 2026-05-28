local Players = game:GetService("Players")

local UIEffectCallbacks = {}

local activeBindings = setmetatable({}, { __mode = "k" })
local loadedTriggers = nil
local rootConnections = {}
local started = false

local function disconnectConnection(connection)
	if typeof(connection) == "RBXScriptConnection" then
		connection:Disconnect()
	end
end

local function runCleanup(cleanup)
	local cleanupType = typeof(cleanup)

	if cleanupType == "RBXScriptConnection" then
		cleanup:Disconnect()
		return
	end

	if cleanupType == "function" then
		cleanup()
		return
	end

	if cleanupType == "table" and typeof(cleanup.Disconnect) == "function" then
		cleanup:Disconnect()
		return
	end

	if cleanupType == "table" and typeof(cleanup.Destroy) == "function" then
		cleanup:Destroy()
	end
end

local function appendCleanup(targetCleanups, cleanup)
	if cleanup == nil then
		return
	end

	if typeof(cleanup) == "table" and cleanup.Disconnect == nil and cleanup.Destroy == nil then
		for _, nestedCleanup in ipairs(cleanup) do
			appendCleanup(targetCleanups, nestedCleanup)
		end
		return
	end

	table.insert(targetCleanups, cleanup)
end

local function loadTriggers()
	if loadedTriggers then
		return loadedTriggers
	end

	loadedTriggers = {}

	for _, descendant in ipairs(script:GetDescendants()) do
		if descendant:IsA("ModuleScript") and descendant.Name == "Trigger" then
			local ok, triggerModule = pcall(require, descendant)
			if ok and type(triggerModule) == "table" and typeof(triggerModule.Bind) == "function" then
				table.insert(loadedTriggers, triggerModule)
			else
				warn(string.format("[UIEffectCallbacks] Failed to load trigger %s", descendant:GetFullName()))
			end
		end
	end

	table.sort(loadedTriggers, function(left, right)
		return (left.Name or left.__file or "") < (right.Name or right.__file or "")
	end)

	return loadedTriggers
	end

local function cleanupButton(button)
	local bindingState = activeBindings[button]
	if not bindingState then
		return
	end

	activeBindings[button] = nil

	for _, cleanup in ipairs(bindingState.Cleanups) do
		local ok, err = pcall(runCleanup, cleanup)
		if not ok then
			warn(string.format("[UIEffectCallbacks] Cleanup failed for %s: %s", button:GetFullName(), tostring(err)))
		end
	end

	disconnectConnection(bindingState.DestroyingConnection)
	end

local function shouldBind(instance)
	return instance:IsA("GuiButton")
	end

local function bindButton(button)
	if activeBindings[button] then
		return
	end

	local cleanups = {}

	for _, trigger in ipairs(loadTriggers()) do
		local canBind = true
		if typeof(trigger.ShouldBind) == "function" then
			local ok, result = pcall(trigger.ShouldBind, button)
			canBind = ok and result == true
			if not ok then
				warn(string.format("[UIEffectCallbacks] Trigger filter failed for %s on %s", trigger.Name or "Unknown", button:GetFullName()))
			end
		end

		if canBind then
			local ok, cleanupOrList = pcall(trigger.Bind, button)
			if ok then
				appendCleanup(cleanups, cleanupOrList)
			else
				warn(string.format("[UIEffectCallbacks] Trigger bind failed for %s on %s", trigger.Name or "Unknown", button:GetFullName()))
			end
		end
	end

	activeBindings[button] = {
		Cleanups = cleanups,
		DestroyingConnection = button.Destroying:Connect(function()
			cleanupButton(button)
		end),
	}
	end

local function bindExistingButtons(root)
	if shouldBind(root) then
		bindButton(root)
	end

	for _, descendant in ipairs(root:GetDescendants()) do
		if shouldBind(descendant) then
			bindButton(descendant)
		end
	end
	end

local function observeRoot(root)
	bindExistingButtons(root)

	table.insert(rootConnections, root.DescendantAdded:Connect(function(descendant)
		if shouldBind(descendant) then
			bindButton(descendant)
		end
	end))

	table.insert(rootConnections, root.DescendantRemoving:Connect(function(descendant)
		if shouldBind(descendant) then
			cleanupButton(descendant)
		end
	end))
	end

function UIEffectCallbacks.Start(roots)
	if started then
		return
	end

	started = true

	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		error("UIEffectCallbacks.Start must run on the client")
	end

	local resolvedRoots = roots
	if resolvedRoots == nil then
		resolvedRoots = {
			localPlayer:WaitForChild("PlayerGui"),
			workspace,
		}
	end

	for _, root in ipairs(resolvedRoots) do
		observeRoot(root)
	end
	end

function UIEffectCallbacks.Stop()
	if not started then
		return
	end

	started = false

	for button in pairs(activeBindings) do
		cleanupButton(button)
	end

	for _, connection in ipairs(rootConnections) do
		disconnectConnection(connection)
	end

	table.clear(rootConnections)
	end

return UIEffectCallbacks
