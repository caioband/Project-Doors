local ConnectionPlus = {}

local connections = setmetatable({}, {
	__mode = "k",
})

local function disconnectConnection(connection)
	if connection and connection.Connected then
		connection:Disconnect()
	end
end

local function clearInstanceBucket(instance)
	local bucket = connections[instance]

	if not bucket then
		return
	end

	for _, entry in pairs(bucket.events) do
		disconnectConnection(entry.connection)
	end

	disconnectConnection(bucket.destroyingConnection)
	connections[instance] = nil
	return nil
	end

local function ensureInstanceBucket(instance)
	local bucket = connections[instance]

	if bucket then
		return bucket
	end

	bucket = {
		events = {},
	}

	if typeof(instance) == "Instance" then
		bucket.destroyingConnection = instance.Destroying:Connect(function()
			clearInstanceBucket(instance)
		end)
	end

	connections[instance] = bucket
	return bucket
end

function ConnectionPlus:ConnectWithInfo(instance, eventName, signal, callback)
	local bucket = ensureInstanceBucket(instance)
	self:Disconnect(instance, eventName)

	local connection = signal:Connect(callback)

	bucket.events[eventName] = {
		connection = connection,
	}

	return connection
end

function ConnectionPlus:Connect(instance, eventName, signal, callback)
	return self:ConnectWithInfo(instance, eventName, signal, callback)
end

function ConnectionPlus:Disconnect(instance, eventName)
    local bucket = connections[instance]

	if not bucket then
		return
	end

	local entry = bucket.events[eventName]

	if not entry then
		return
	end

	disconnectConnection(entry.connection)
	bucket.events[eventName] = nil

	if next(bucket.events) == nil then
		clearInstanceBucket(instance)
	end
end

function ConnectionPlus:DisconnectAll(instance)
	clearInstanceBucket(instance)
end


return ConnectionPlus