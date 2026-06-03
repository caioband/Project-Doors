local TeleportService = game:GetService("TeleportService")

local SafeTeleport = {}


local MAX_RETRIES = 3
local RETRY_DELAY = 2


function SafeTeleport:Teleport(placeId, players, teleportOptions)
	assert(typeof(placeId) == "number", "placeId must be a number")
	assert(typeof(players) == "table", "players must be an array")

	for attempt = 1, MAX_RETRIES do
		local success, result = pcall(function()
			return TeleportService:TeleportAsync(placeId, players, teleportOptions)
		end)

		if success then
			return true, result
		end

		print(string.format("Teleport attempt %d failed: %s", attempt, result))

		if attempt < MAX_RETRIES then
			task.wait(RETRY_DELAY)
		end
	end

	return false, "Teleport failed after retries"
end

function SafeTeleport:ReserveServerAndTeleport(placeId, players)
	assert(typeof(placeId) == "number", "placeId must be a number")
	assert(typeof(players) == "table", "players must be an array")
	assert(#players > 0, "players array is empty")

	local reserveSuccess, codeOrError, privateServerId = pcall(function()
		return TeleportService:ReserveServerAsync(placeId)
	end)

	if not reserveSuccess then
		return false, "ReserveServerAsync failed: " .. tostring(codeOrError)
	end

	local code = codeOrError
	local lastError

	for attempt = 1, MAX_RETRIES do
		local options = Instance.new("TeleportOptions")
		options.ReservedServerAccessCode = code

		local teleportSuccess, teleportError = pcall(function()
			TeleportService:TeleportAsync(placeId, players, options)
		end)

		options:Destroy()

		if teleportSuccess then
			return true, code
		end

		lastError = teleportError
		warn(`Teleport attempt {attempt} failed: {teleportError}`)

		if attempt < MAX_RETRIES then
			task.wait(RETRY_DELAY)
		end
	end

	return false, "TeleportAsync failed after retries: " .. tostring(lastError)
end

return SafeTeleport