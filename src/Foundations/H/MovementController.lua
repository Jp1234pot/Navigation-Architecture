
-- Navigation Architecture v2.2
-- Module: MovementController
-- Foundation H: explicit, bounded, client-side waypoint execution.
-- This module does not select targets, compute paths, or replan routes. (you reading? ehh)

local MovementController = {}
MovementController.__index = MovementController

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

local function disconnect(connection)
    if connection then
        pcall(function()
            connection:Disconnect()
        end)
    end
end

function MovementController.new(config, characterManager)
    assert(type(config) == "table", "MovementController requires validated config")
    assert(type(config.movementEnabled) == "boolean", "movementEnabled is required")
    assert(type(config.maxTrackedWaypoints) == "number", "maxTrackedWaypoints is required")
    assert(isFiniteNumber(config.movementRouteTimeout)
        and config.movementRouteTimeout >= 30 and config.movementRouteTimeout <= 900,
        "movementRouteTimeout must be between 30 and 900 seconds")
    assert(characterManager ~= nil, "MovementController requires CharacterManager")

    return setmetatable({
        Config = config,
        CharacterManager = characterManager,
        _status = "Idle",
        _reason = "Initialized",
        _character = nil,
        _humanoid = nil,
        _root = nil,
        _waypoints = {},
        _waypointIndex = 0,
        _requestId = nil,
        _activeWaypointPosition = nil,
        _moveConnection = nil,
        _segmentTimeoutThread = nil,
        _routeTimeoutThread = nil,
        _diedConnection = nil,
        _ancestryConnection = nil,
        _onStatus = nil,
        _generation = 0,
        _destroyed = false,
    }, MovementController)
end

function MovementController:_emit(status, reason)
    self._status = status
    self._reason = reason or status
    if self._onStatus then
        local ok, err = pcall(self._onStatus, {
            status = status,
            reason = self._reason,
            requestId = self._requestId,
            waypointIndex = self._waypointIndex,
            waypointCount = #self._waypoints,
            timestamp = os.clock(),
        })
        if not ok then
            warn("[Navigation v2.2] Movement status callback failed: " .. tostring(err))
        end
    end
end

function MovementController:SetOnStatus(callbackOrNil)
    if self._destroyed then
        return false, "Destroyed"
    end
    assert(callbackOrNil == nil or type(callbackOrNil) == "function",
        "status callback must be a function or nil")
    self._onStatus = callbackOrNil
    return true
end

function MovementController:GetStatus()
    return {
        status = self._status,
        reason = self._reason,
        requestId = self._requestId,
        waypointIndex = self._waypointIndex,
        waypointCount = #self._waypoints,
        active = self._status == "Moving",
    }
end

function MovementController:_cancelSegmentTimeout()
    if self._segmentTimeoutThread then
        pcall(function()
            task.cancel(self._segmentTimeoutThread)
        end)
        self._segmentTimeoutThread = nil
    end
end

function MovementController:_cancelRouteTimeout()
    if self._routeTimeoutThread then
        pcall(function()
            task.cancel(self._routeTimeoutThread)
        end)
        self._routeTimeoutThread = nil
    end
end

function MovementController:_disconnectSignals()
    self:_cancelSegmentTimeout()
    self:_cancelRouteTimeout()
    disconnect(self._moveConnection)
    disconnect(self._diedConnection)
    disconnect(self._ancestryConnection)
    self._moveConnection = nil
    self._diedConnection = nil
    self._ancestryConnection = nil
end

function MovementController:_isCharacterUsable()
    local character = self._character
    local humanoid = self._humanoid
    local root = self._root

    if not character or not humanoid or not root then
        return false, "CharacterUnavailable"
    end
    if self.CharacterManager:GetCharacter() ~= character then
        return false, "CharacterChanged"
    end
    if not character:IsDescendantOf(workspace) or not root:IsDescendantOf(character) then
        return false, "CharacterUnavailable"
    end
    if humanoid.Health <= 0 then
        return false, "CharacterDead"
    end
    if root.Anchored then
        return false, "RootAnchored"
    end
    if humanoid.Sit or humanoid.SeatPart ~= nil then
        return false, "CharacterSeated"
    end
    return true, "Ready"
end

function MovementController:_finish(status, reason, haltAtCurrentPosition)
    if self._status ~= "Moving" then
        return false, self._status
    end

    self._generation += 1
    self:_disconnectSignals()

    if haltAtCurrentPosition and self._humanoid and self._root
        and self._humanoid.Parent and self._root.Parent
        and self._humanoid.Health > 0 then
        pcall(function()
            self._humanoid:MoveTo(self._root.Position)
        end)
    end

    self._activeWaypointPosition = nil
    self:_emit(status, reason)
    return true, status
end

function MovementController:_issueCurrentWaypoint(generation)
    if self._destroyed or generation ~= self._generation or self._status ~= "Moving" then
        return false, "Inactive"
    end

    local usable, reason = self:_isCharacterUsable()
    if not usable then
        self:_finish("Stopped", reason, false)
        return false, reason
    end

    local waypoint = self._waypoints[self._waypointIndex]
    if not waypoint then
        self:_finish("Completed", "RouteCompleted", false)
        return true, "Completed"
    end

    if waypoint.action == Enum.PathWaypointAction.Jump then
        if not self.Config.agentCanJump then
            self:_finish("Failed", "JumpWaypointButAgentJumpDisabled", true)
            return false, "JumpWaypointButAgentJumpDisabled"
        end
        local jumpEnabled = false
        local readOk = pcall(function()
            jumpEnabled = self._humanoid:GetStateEnabled(Enum.HumanoidStateType.Jumping)
        end)
        if not readOk or not jumpEnabled then
            self:_finish("Failed", "JumpStateUnavailable", true)
            return false, "JumpStateUnavailable"
        end
        local jumpWriteOk = pcall(function()
            self._humanoid.Jump = true
        end)
        if not jumpWriteOk then
            self:_finish("Failed", "JumpCommandFailed", true)
            return false, "JumpCommandFailed"
        end
    end

    self._activeWaypointPosition = waypoint.position
    self:_cancelSegmentTimeout()
    local waypointIndex = self._waypointIndex
    self._segmentTimeoutThread = task.delay(self.Config.movementSegmentTimeout, function()
        if not self._destroyed and generation == self._generation
            and self._status == "Moving" and self._waypointIndex == waypointIndex then
            self._segmentTimeoutThread = nil
            self:_finish("Failed", "MovementSegmentWatchdogExpired", false)
        end
    end)

    self:_emit("Moving", "WaypointIssued")
    if self._destroyed or generation ~= self._generation or self._status ~= "Moving" then
        return false, "StoppedBeforeMoveCommand"
    end

    local moveOk, moveError = pcall(function()
        self._humanoid:MoveTo(waypoint.position)
    end)
    if not moveOk then
        self:_finish("Failed", "MoveToCallFailed: " .. tostring(moveError), false)
        return false, "MoveToCallFailed"
    end

    return true, "Moving"
end

function MovementController:_onMoveToFinished(reached, generation)
    if self._destroyed or generation ~= self._generation or self._status ~= "Moving" then
        return
    end

    self:_cancelSegmentTimeout()

    local usable, reason = self:_isCharacterUsable()
    if not usable then
        self:_finish("Stopped", reason, false)
        return
    end

    local expected = self._activeWaypointPosition
    if not expected then
        self:_finish("Failed", "MissingActiveWaypoint", false)
        return
    end

    local walkToPointOk, walkToPoint = pcall(function()
        return self._humanoid.WalkToPoint
    end)
    if not walkToPointOk or not isFiniteVector3(walkToPoint)
        or (walkToPoint - expected).Magnitude > 0.1 then
        self:_finish("Stopped", "MovementGoalChangedExternally", false)
        return
    end

    if not reached then
        self:_finish("Failed", "MoveToTimedOutOrInterrupted", false)
        return
    end

    self._waypointIndex += 1
    self:_emit("Moving", "WaypointReached")
    self:_issueCurrentWaypoint(generation)
end

function MovementController:Start(character, pathPacket)
    if self._destroyed then return false, "Destroyed" end
    if not self.Config.enabled then return false, "NavigationDisabled" end
    if not self.Config.pathfindingEnabled then return false, "PathfindingDisabled" end
    if not self.Config.movementEnabled then return false, "MovementDisabled" end
    if self._status == "Moving" then return false, "AlreadyMoving" end
    if type(pathPacket) ~= "table" or pathPacket.status ~= "Success" then
        return false, "PathNotSuccessful"
    end
    if not character or not character:IsA("Model") then
        return false, "InvalidCharacter"
    end
    if self.CharacterManager:GetCharacter() ~= character then
        return false, "NotLocalCharacter"
    end

    local rawWaypoints = pathPacket.waypoints
    if type(rawWaypoints) ~= "table" then return false, "InvalidWaypoints" end
    local count = #rawWaypoints
    if count < 1 then return false, "EmptyWaypoints" end
    if count > self.Config.maxTrackedWaypoints then return false, "WaypointLimitExceeded" end

    -- Copy and validate the complete bounded route before issuing any movement.
    local copied = table.create(count)
    for index = 1, count do
        local waypoint = rawWaypoints[index]
        if type(waypoint) ~= "table" or not isFiniteVector3(waypoint.position) then
            return false, "InvalidWaypointAtIndex" .. tostring(index)
        end
        local action = waypoint.action
        if action ~= nil and action ~= Enum.PathWaypointAction.Walk
            and action ~= Enum.PathWaypointAction.Jump then
            return false, "UnsupportedWaypointActionAtIndex" .. tostring(index)
        end
        if waypoint.label ~= nil and waypoint.label ~= "" then
            return false, "UnsupportedCustomLinkAtIndex" .. tostring(index)
        end
        copied[index] = {
            position = waypoint.position,
            action = action or Enum.PathWaypointAction.Walk,
        }
    end

    local humanoid = self.CharacterManager:GetHumanoid(character)
    local root = self.CharacterManager:GetRoot(character)
    if not humanoid or not root or not self.CharacterManager:IsAlive(character) then
        return false, "CharacterNotReady"
    end
    if root.Anchored then return false, "RootAnchored" end
    if humanoid.Sit or humanoid.SeatPart ~= nil then return false, "CharacterSeated" end

    self:_disconnectSignals()
    self._generation += 1
    local generation = self._generation
    self._character = character
    self._humanoid = humanoid
    self._root = root
    self._waypoints = copied
    self._waypointIndex = 1
    self._requestId = pathPacket.requestId
    self._activeWaypointPosition = nil
    self._status = "Moving"
    self._reason = "Starting"

    self._routeTimeoutThread = task.delay(self.Config.movementRouteTimeout, function()
        if not self._destroyed and generation == self._generation and self._status == "Moving" then
            self._routeTimeoutThread = nil
            self:_finish("Failed", "MovementRouteWatchdogExpired", false)
        end
    end)

    self._moveConnection = humanoid.MoveToFinished:Connect(function(reached)
        self:_onMoveToFinished(reached, generation)
    end)
    self._diedConnection = humanoid.Died:Connect(function()
        if generation == self._generation then
            self:_finish("Stopped", "CharacterDied", false)
        end
    end)
    self._ancestryConnection = character.AncestryChanged:Connect(function(_, parent)
        if parent == nil and generation == self._generation then
            self:_finish("Stopped", "CharacterRemoved", false)
        end
    end)

    self:_emit("Moving", "RouteStarted")
    return self:_issueCurrentWaypoint(generation)
end

function MovementController:Stop(reason)
    if self._destroyed then return false, "Destroyed" end
    if self._status ~= "Moving" then return false, self._status end
    return self:_finish("Stopped", reason or "StoppedByCaller", true)
end

function MovementController:Destroy()
    if self._destroyed then return end
    if self._status == "Moving" then
        self:_finish("Stopped", "Destroyed", true)
    else
        self:_disconnectSignals()
    end
    table.clear(self._waypoints)
    self._character = nil
    self._humanoid = nil
    self._root = nil
    self._activeWaypointPosition = nil
    self:_cancelSegmentTimeout()
    self:_cancelRouteTimeout()
    self._onStatus = nil
    self._requestId = nil
    self._status = "Destroyed"
    self._reason = "Destroyed"
    self._destroyed = true
end

return MovementController
