
-- Navigation Architecture v2.2
-- Module: PathfindingEngine
-- Foundation F: explicit client-side path computation, with no movement control.

local PathfindingService = game:GetService("PathfindingService")

local PathfindingEngine = {}
PathfindingEngine.__index = PathfindingEngine

local function isFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function isFiniteVector3(value)
    return typeof(value) == "Vector3"
        and isFiniteNumber(value.X)
        and isFiniteNumber(value.Y)
        and isFiniteNumber(value.Z)
end

local function copyWaypoints(waypoints)
    local result = {}
    for index, waypoint in ipairs(waypoints) do
        result[index] = {
            index = index,
            position = waypoint.Position,
            action = waypoint.Action,
            label = waypoint.Label,
        }
    end
    return result
end

local function copyPacket(packet)
    if not packet then
        return nil
    end

    local result = {}
    for key, value in pairs(packet) do
        if key == "waypoints" and type(value) == "table" then
            local copied = {}
            for index, waypoint in ipairs(value) do
                copied[index] = {
                    index = waypoint.index,
                    position = waypoint.position,
                    action = waypoint.action,
                    label = waypoint.label,
                }
            end
            result.waypoints = copied
        else
            result[key] = value
        end
    end
    return result
end

function PathfindingEngine.new(config)
    assert(type(config) == "table", "PathfindingEngine requires validated config")

    return setmetatable({
        Config = config,
        _generation = 0,
        _lastRequestAt = nil,
        _activePath = nil,
        _activeConnections = {},
        _pendingPaths = {},
        _computeInFlight = false,
        _latest = nil,
        _onResult = nil,
        _onBlocked = nil,
        _onUnblocked = nil,
        _destroyed = false,
    }, PathfindingEngine)
end

function PathfindingEngine:SetOnResult(callback)
    if self._destroyed then
        return false, "Destroyed"
    end
    if callback ~= nil and type(callback) ~= "function" then
        return false, "CallbackMustBeFunctionOrNil"
    end
    self._onResult = callback
    return true, "OK"
end

function PathfindingEngine:SetOnBlocked(callback)
    if self._destroyed then
        return false, "Destroyed"
    end
    if callback ~= nil and type(callback) ~= "function" then
        return false, "CallbackMustBeFunctionOrNil"
    end
    self._onBlocked = callback
    return true, "OK"
end

function PathfindingEngine:SetOnUnblocked(callback)
    if self._destroyed then
        return false, "Destroyed"
    end
    if callback ~= nil and type(callback) ~= "function" then
        return false, "CallbackMustBeFunctionOrNil"
    end
    self._onUnblocked = callback
    return true, "OK"
end

function PathfindingEngine:_emit(callback, packet, label)
    if not callback then
        return
    end
    local success, err = pcall(callback, copyPacket(packet))
    if not success then
        warn("[Navigation v2.2] PathfindingEngine " .. label .. " callback failed: " .. tostring(err))
    end
end

function PathfindingEngine:_disconnectActivePath()
    for _, connection in ipairs(self._activeConnections) do
        if connection then
            local connectedSuccess, isConnected = pcall(function()
                return connection.Connected
            end)

            if connectedSuccess and isConnected then
                pcall(function()
                    connection:Disconnect()
                end)
            end
        end
    end
    table.clear(self._activeConnections)

    local path = self._activePath
    self._activePath = nil
    if path then
        pcall(function()
            path:Destroy()
        end)
    end
end

function PathfindingEngine:_agentParameters()
    local config = self.Config
    local costs = {}
    for key, value in pairs(config.pathCosts) do
        costs[key] = value
    end

    return {
        AgentRadius = config.agentRadius,
        AgentHeight = config.agentHeight,
        AgentCanJump = config.agentCanJump,
        AgentCanClimb = config.agentCanClimb,
        WaypointSpacing = config.waypointSpacing,
        Costs = costs,
    }
end

function PathfindingEngine:_publish(packet)
    self._latest = packet
    self:_emit(self._onResult, packet, "result")
end

function PathfindingEngine:_completeFailure(requestId, startPosition, finishPosition, status, detail)
    if self._destroyed or requestId ~= self._generation then
        return
    end

    self:_publish({
        requestId = requestId,
        status = status,
        detail = detail,
        startPosition = startPosition,
        finishPosition = finishPosition,
        requestedAt = self._lastRequestAt,
        completedAt = os.clock(),
        waypoints = {},
    })
end

function PathfindingEngine:RequestPath(startPosition, finishPosition)
    if self._destroyed then
        return false, nil, "Destroyed"
    end
    if self.Config.pathfindingEnabled ~= true then
        return false, nil, "Disabled"
    end
    if self._computeInFlight then
        return false, nil, "ComputeInProgress"
    end
    if not isFiniteVector3(startPosition) or not isFiniteVector3(finishPosition) then
        return false, nil, "InvalidPosition"
    end

    local now = os.clock()
    if self._lastRequestAt and now - self._lastRequestAt < self.Config.pathRequestMinInterval then
        return false, nil, "RateLimited"
    end

    self._generation = self._generation + 1
    local requestId = self._generation
    self._lastRequestAt = now
    self._computeInFlight = true
    self:_disconnectActivePath()

    self:_publish({
        requestId = requestId,
        status = "Computing",
        startPosition = startPosition,
        finishPosition = finishPosition,
        requestedAt = now,
        waypoints = {},
    })

    task.spawn(function()
        if self._destroyed or requestId ~= self._generation then
            self._computeInFlight = false
            return
        end

        local createSuccess, pathOrError = pcall(function()
            return PathfindingService:CreatePath(self:_agentParameters())
        end)

        if not createSuccess then
            self._computeInFlight = false
            self:_completeFailure(requestId, startPosition, finishPosition, "CreatePathFailed", tostring(pathOrError))
            return
        end

        local path = pathOrError
        self._pendingPaths[path] = true

        if self._destroyed or requestId ~= self._generation then
            self._pendingPaths[path] = nil
            self._computeInFlight = false
            pcall(function() path:Destroy() end)
            return
        end

        local computeSuccess, computeError = pcall(function()
            path:ComputeAsync(startPosition, finishPosition)
        end)

        self._pendingPaths[path] = nil
        self._computeInFlight = false

        if self._destroyed or requestId ~= self._generation then
            pcall(function() path:Destroy() end)
            return
        end

        if not computeSuccess then
            pcall(function() path:Destroy() end)
            self:_completeFailure(requestId, startPosition, finishPosition, "ComputeFailed", tostring(computeError))
            return
        end

        local statusSuccess, pathStatus = pcall(function()
            return path.Status
        end)
        if not statusSuccess then
            pcall(function() path:Destroy() end)
            self:_completeFailure(requestId, startPosition, finishPosition, "StatusReadFailed", tostring(pathStatus))
            return
        end

        if pathStatus ~= Enum.PathStatus.Success then
            pcall(function() path:Destroy() end)
            self:_completeFailure(requestId, startPosition, finishPosition, tostring(pathStatus), nil)
            return
        end

        local waypointSuccess, rawWaypoints = pcall(function()
            return path:GetWaypoints()
        end)
        if not waypointSuccess or type(rawWaypoints) ~= "table" or #rawWaypoints == 0 then
            pcall(function() path:Destroy() end)
            self:_completeFailure(requestId, startPosition, finishPosition, "WaypointReadFailedOrEmpty", waypointSuccess and nil or tostring(rawWaypoints))
            return
        end

        local waypoints = copyWaypoints(rawWaypoints)
        self._activePath = path

        local blockedConnectSuccess, blockedConnectionOrError = pcall(function()
            return path.Blocked:Connect(function(blockedWaypointIndex)
                if self._destroyed or requestId ~= self._generation or self._activePath ~= path then
                    return
                end
                self:_emit(self._onBlocked, {
                    requestId = requestId,
                    blockedWaypointIndex = blockedWaypointIndex,
                    timestamp = os.clock(),
                    note = "Raw engine event; index may refer to a waypoint behind the agent.",
                }, "blocked")
            end)
        end)

        if not blockedConnectSuccess then
            self._activePath = nil
            pcall(function()
                path:Destroy()
            end)
            self:_completeFailure(
                requestId,
                startPosition,
                finishPosition,
                "BlockedConnectionFailed",
                tostring(blockedConnectionOrError)
            )
            return
        end

        local blockedConnection = blockedConnectionOrError

        local unblockedConnectSuccess, unblockedConnectionOrError = pcall(function()
            return path.Unblocked:Connect(function(unblockedWaypointIndex)
                if self._destroyed or requestId ~= self._generation or self._activePath ~= path then
                    return
                end
                self:_emit(self._onUnblocked, {
                    requestId = requestId,
                    unblockedWaypointIndex = unblockedWaypointIndex,
                    timestamp = os.clock(),
                }, "unblocked")
            end)
        end)

        if not unblockedConnectSuccess then
            pcall(function()
                blockedConnection:Disconnect()
            end)

            self._activePath = nil
            pcall(function()
                path:Destroy()
            end)
            self:_completeFailure(
                requestId,
                startPosition,
                finishPosition,
                "UnblockedConnectionFailed",
                tostring(unblockedConnectionOrError)
            )
            return
        end

        local unblockedConnection = unblockedConnectionOrError

        table.insert(self._activeConnections, blockedConnection)
        table.insert(self._activeConnections, unblockedConnection)

        self:_publish({
            requestId = requestId,
            status = "Success",
            startPosition = startPosition,
            finishPosition = finishPosition,
            requestedAt = self._lastRequestAt,
            completedAt = os.clock(),
            waypoints = waypoints,
        })
    end)

    return true, requestId, "Queued"
end

function PathfindingEngine:Cancel(reason)
    if self._destroyed then
        return false, "Destroyed"
    end

    self._generation = self._generation + 1
    self:_disconnectActivePath()
    self:_publish({
        requestId = self._generation,
        status = "Cancelled",
        detail = reason or "CancelledByCaller",
        timestamp = os.clock(),
        waypoints = {},
    })
    return true, "Cancelled"
end

function PathfindingEngine:GetLatest()
    return copyPacket(self._latest)
end

function PathfindingEngine:Destroy()
    if self._destroyed then
        return
    end

    self._destroyed = true
    self._generation = self._generation + 1
    self:_disconnectActivePath()
    self._latest = nil
    self._onResult = nil
    self._onBlocked = nil
    self._onUnblocked = nil
    -- In-flight ComputeAsync calls cannot be interrupted. Their results are
    -- invalidated by the generation token and their Path is destroyed on return.
end

return PathfindingEngine
