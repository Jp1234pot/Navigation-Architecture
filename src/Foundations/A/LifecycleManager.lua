
-- Navigation Architecture v2.2
-- Foundation A: LifecycleManager
-- Reconstructed implementation.
-- Compatible with the documented Foundation H interface.

local LifecycleManager = {}
LifecycleManager.__index = LifecycleManager

local MAX_CONNECTIONS = 64
local MAX_CLEANUPS = 32

function LifecycleManager.new()
	local self = setmetatable({}, LifecycleManager)

	self._connections = {}
	self._connectionKeys = {}
	self._cleanups = {}

	self._connectionCount = 0
	self._cleanupCount = 0
	self._destroyed = false

	return self
end

function LifecycleManager:Connect(signal, callback, key)
	if self._destroyed then
		return nil
	end

	assert(signal ~= nil, "Connect requires a signal")
	assert(type(callback) == "function", "Connect requires a callback")

	local previousConnection = nil

	if key ~= nil then
		assert(type(key) == "string", "Connection key must be a string")
		assert(key ~= "", "Connection key cannot be empty")

		previousConnection = self._connectionKeys[key]
	end

	if self._connectionCount >= MAX_CONNECTIONS and not previousConnection then
		warn("[LifecycleManager] Connection limit reached")
		return nil
	end

	local success, connection = pcall(function()
		return signal:Connect(callback)
	end)

	if not success then
		warn("[LifecycleManager] Connect failed: " .. tostring(connection))
		return nil
	end

	if not connection then
		return nil
	end

	if previousConnection then
		self:Disconnect(previousConnection)
	end

	self._connections[connection] = true
	self._connectionCount += 1

	if key then
		self._connectionKeys[key] = connection
	end

	return connection
end

function LifecycleManager:Disconnect(connectionOrKey)
	if self._destroyed then
		return false
	end

	local connection = connectionOrKey

	if type(connectionOrKey) == "string" then
		connection = self._connectionKeys[connectionOrKey]
	end

	if not connection or not self._connections[connection] then
		return false
	end

	self._connections[connection] = nil
	self._connectionCount -= 1

	for key, storedConnection in pairs(self._connectionKeys) do
		if storedConnection == connection then
			self._connectionKeys[key] = nil
		end
	end

	local success, err = pcall(function()
		connection:Disconnect()
	end)

	if not success then
		warn("[LifecycleManager] Disconnect failed: " .. tostring(err))
	end

	return success
end

function LifecycleManager:AddCleanup(callback)
	if self._destroyed then
		return false
	end

	assert(type(callback) == "function", "Cleanup must be a function")

	if self._cleanupCount >= MAX_CLEANUPS then
		warn("[LifecycleManager] Cleanup limit reached")
		return false
	end

	self._cleanupCount += 1
	table.insert(self._cleanups, callback)

	return true
end

function LifecycleManager:Destroy()
	if self._destroyed then
		return
	end

	self._destroyed = true

	for connection in pairs(self._connections) do
		local success, err = pcall(function()
			connection:Disconnect()
		end)

		if not success then
			warn("[LifecycleManager] Cleanup disconnect failed: " .. tostring(err))
		end
	end

	table.clear(self._connections)
	table.clear(self._connectionKeys)

	self._connectionCount = 0

	for index = #self._cleanups, 1, -1 do
		local cleanup = self._cleanups[index]

		local success, err = pcall(cleanup)

		if not success then
			warn("[LifecycleManager] Cleanup callback failed: " .. tostring(err))
		end
	end

	table.clear(self._cleanups)
	self._cleanupCount = 0
end

return LifecycleManager
