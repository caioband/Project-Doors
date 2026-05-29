local ConnectionPlus = {}

local connections = {}

function ConnectionPlus:ConnectWithInfo(instance, eventName, signal, callback)
	local connection = signal:Connect(callback)
    
	if not connections[instance] then
		connections[instance] = {}
	end

	if not connections[instance][eventName] then
		connections[instance][eventName] = {}
	end

	connections[instance][eventName] = {
		instance = instance,
		eventName = eventName,
	}

	return connection
end

function ConnectionPlus:Connect(instance, eventName, signal, callback)
    self:ConnectWithInfo(instance, eventName, signal, callback)
end

function ConnectionPlus:Disconnect(instance, eventName)
    if connections[instance] then
        if connections[instance][eventName] then
            connections[instance][eventName] = nil
        end
    end
end


return ConnectionPlus