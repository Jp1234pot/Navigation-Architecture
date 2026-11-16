
-- Navigation Architecture v2.2
-- Module: MovementController
-- Foundation H: explicit, bounded, client-side waypoint execution.
-- This module does not select targets, compute paths, or replan routes.

local MovementController = {}
MovementController.__index = MovementController

local function isFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function isFiniteInteger(value)
    return isFiniteNumber(value) and value % 1 == 0
end

local function isFiniteVector3(value)
    return typeof(value) == "Vector3"
        and isFiniteNumber(value.X)
        and isFiniteNumber(value.Y)
        and isFiniteNumber(value.Z)
end

local function isModel(value)
    if typeof(value) ~= "Instance" then
        return false
    end

    local ok, result = pcall(function()
        return value:IsA("Model")
    end)

    return ok and result
end

local function disconnect(connection)
    if connection then
        pcall(function()
            connection:Disconnect()
        end)
    end
end

-- Rejects sparse arrays, invalid keys, and entries beyond the configured limit.
-- Uses next/rawget so array validation does not depend on # for malformed tables.
local function getDenseArrayLength(array, maximum)
    if type(array) ~= "table" then
        return nil
    end

    local count = 0
    local highestIndex = 0
    local key = nil

    while true do
        local nextKey = next(array, key)
        if nextKey == nil then
            break
        end

        key = nextKey

        if not isFiniteInteger(key) or key < 1 or key > maximum then
            return nil
        end

        count += 1
        if key > highestIndex then
            highestIndex = key
        end
    end

    if count ~= highestIndex then
        return nil
    end

    return count
end

function MovementController.new(config, characterManager)
    assert(type(config) == "table", "MovementController requires validated config")
    assert(type(config.movementEnabled) == "boolean", "movementEnabled is required")

    assert(
        isFiniteInteger(config.maxTrackedWaypoints)
            and config.maxTrackedWaypoints >= 1
            and config.maxTrackedWaypoints <= 2048,
        "maxTrackedWaypoints must be an integer from 1 to 2048"
    )

    assert(
        isFiniteNumber(config.movementSegmentTimeout)
            and config.movementSegmentTimeout >= 8.1
            and config.movementSegmentTimeout <= 15,
        "movementSegmentTimeout must be between 8.1 and 15 seconds"
    )

    assert(
        isFiniteNumber(config.movementRouteTimeout)
            and config.movementRouteTimeout >= 30
            and config.movementRouteTimeout <= 900,
        "movementRouteTimeout must be between 30 and 900 seconds"
    )

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
        _diedConnection = nil,
        _ancestryConnection = nil,

        _segmentTimeoutThread = nil,
        _routeTimeoutThread = nil,

        _onStatus = nil,
        _generation = 0,
        _destroyed = false,
    }, MovementController)
end

function MovementController:_emit(status, reason)
    self._status = status
    self._reason = reason or status

    local callback = self._onStatus
    if callback then
        local ok, err = pcall(callback, {
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

    if callbackOrNil ~= nil and type(callbackOrNil) ~= "function" then
        return false, "CallbackMustBeFunctionOrNil"
    end

    self._onStatus = callbackOrNil
    return true, "OK"
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
    local thread = self._segmentTimeoutThread
    self._segmentTimeoutThread = nil

    if thread then
        pcall(function()
            task.cancel(thread)
        end)
    end
end

function MovementController:_cancelRouteTimeout()
    local thread = self._routeTimeoutThread
    self._routeTimeoutThread = nil

    if thread then
        pcall(function()
            task.cancel(thread)
        end)
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

    if not isModel(character)
        or typeof(humanoid) ~= "Instance"
        or typeof(root) ~= "Instance" then
        return false, "CharacterUnavailable"
    end

    local managerOk, currentCharacter = pcall(function()
        return self.CharacterManager:GetCharacter()
    end)

    if not managerOk or currentCharacter ~= character then
        return false, "CharacterChanged"
    end

    local characterOk, characterPresent = pcall(function()
        return character:IsDescendantOf(workspace)
    end)

    local rootOk, rootPresent = pcall(function()
        return root:IsA("BasePart") and root:IsDescendantOf(character)
    end)

    local humanoidOk, humanoidPresent = pcall(function()
        return humanoid:IsA("Humanoid") and humanoid:IsDescendantOf(character)
    end)

    if not characterOk or not characterPresent
        or not rootOk or not rootPresent
        or not humanoidOk or not humanoidPresent then
        return false, "CharacterUnavailable"
    end

    local stateOk, health, anchored, seated, seatPart = pcall(function()
        return humanoid.Health, root.Anchored, humanoid.Sit, humanoid.SeatPart
    end)

    if not stateOk then
        return false, "CharacterStateUnavailable"
    end

    if health <= 0 then
        return false, "CharacterDead"
    end

    if anchored then
        return false, "RootAnchored"
    end

    if seated or seatPart ~= nil then
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

    if haltAtCurrentPosition then
        local humanoid = self._humanoid
        local root = self._root

        if humanoid and root then
            pcall(function()
                if humanoid.Parent and root.Parent and humanoid.Health > 0 then
                    humanoid:MoveTo(root.Position)
                end
            end)
        end
    end

    self._activeWaypointPosition = nil
    self:_emit(status, reason)

    return true, status
end

function MovementController:_scheduleSegmentTimeout(generation, waypointIndex)
    self:_cancelSegmentTimeout()

    local ok, threadOrError = pcall(function()
        return task.delay(self.Config.movementSegmentTimeout, function()
            if not self._destroyed
                and generation == self._generation
                and self._status == "Moving"
                and self._waypointIndex == waypointIndex then

                self._segmentTimeoutThread = nil
                self:_finish("Failed", "MovementSegmentWatchdogExpired", false)
            end
        end)
    end)

    if not ok or threadOrError == nil then
        self._segmentTimeoutThread = nil
        return false, "SegmentWatchdogStartFailed"
    end

    self._segmentTimeoutThread = threadOrError
    return true, "OK"
end

function MovementController:_scheduleRouteTimeout(generation)
    self:_cancelRouteTimeout()

    local ok, threadOrError = pcall(function()
        return task.delay(self.Config.movementRouteTimeout, function()
            if not self._destroyed
                and generation == self._generation
                and self._status == "Moving" then

                self._routeTimeoutThread = nil
                self:_finish("Failed", "MovementRouteWatchdogExpired", false)
            end
        end)
    end)

    if not ok or threadOrError == nil then
        self._routeTimeoutThread = nil
        return false, "RouteWatchdogStartFailed"
    end

    self._routeTimeoutThread = threadOrError
    return true, "OK"
end

function MovementController:_issueCurrentWaypoint(generation)
    if self._destroyed
        or generation ~= self._generation
        or self._status ~= "Moving" then
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
        if self.Config.agentCanJump ~= true then
            self:_finish("Failed", "JumpWaypointButAgentJumpDisabled", true)
            return false, "JumpWaypointButAgentJumpDisabled"
        end

        local readOk, jumpEnabled = pcall(function()
            return self._humanoid:GetStateEnabled(Enum.HumanoidStateType.Jumping)
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

    local waypointIndex = self._waypointIndex
    local timeoutOk, timeoutReason =
        self:_scheduleSegmentTimeout(generation, waypointIndex)

    if not timeoutOk then
        self:_finish("Failed", timeoutReason, false)
        return false, timeoutReason
    end

    self:_emit("Moving", "WaypointIssued")

    if self._destroyed
        or generation ~= self._generation
        or self._status ~= "Moving" then
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
    if self._destroyed
        or generation ~= self._generation
        or self._status ~= "Moving" then
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

    if not walkToPointOk
        or not isFiniteVector3(walkToPoint)
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

    if self._destroyed
        or generation ~= self._generation
        or self._status ~= "Moving" then
        return
    end

    self:_issueCurrentWaypoint(generation)
end

function MovementController:_connectMovementSignals(generation)
    local humanoid = self._humanoid
    local character = self._character

    local moveOk, moveConnectionOrError = pcall(function()
        return humanoid.MoveToFinished:Connect(function(reached)
            self:_onMoveToFinished(reached, generation)
        end)
    end)

    if not moveOk or not moveConnectionOrError then
        return false, "MoveToFinishedConnectionFailed"
    end

    self._moveConnection = moveConnectionOrError

    local diedOk, diedConnectionOrError = pcall(function()
        return humanoid.Died:Connect(function()
            if generation == self._generation then
                self:_finish("Stopped", "CharacterDied", false)
            end
        end)
    end)

    if not diedOk or not diedConnectionOrError then
        return false, "DiedConnectionFailed"
    end

    self._diedConnection = diedConnectionOrError

    local ancestryOk, ancestryConnectionOrError = pcall(function()
        return character.AncestryChanged:Connect(function(_, parent)
            if parent == nil and generation == self._generation then
                self:_finish("Stopped", "CharacterRemoved", false)
            end
        end)
    end)

    if not ancestryOk or not ancestryConnectionOrError then
        return false, "AncestryConnectionFailed"
    end

    self._ancestryConnection = ancestryConnectionOrError

    return true, "OK"
end

function MovementController:Start(character, pathPacket)
    if self._destroyed then
        return false, "Destroyed"
    end

    if self.Config.enabled ~= true then
        return false, "NavigationDisabled"
    end

    if self.Config.pathfindingEnabled ~= true then
        return false, "PathfindingDisabled"
    end

    if not self.Config.movementEnabled then
        return false, "MovementDisabled"
    end

    if self._status == "Moving" then
        return false, "AlreadyMoving"
    end

    if type(pathPacket) ~= "table" or pathPacket.status ~= "Success" then
        return false, "PathNotSuccessful"
    end

    if not isModel(character) then
        return false, "InvalidCharacter"
    end

    local managerOk, currentCharacter = pcall(function()
        return self.CharacterManager:GetCharacter()
    end)

    if not managerOk or currentCharacter ~= character then
        return false, "NotLocalCharacter"
    end

    local rawWaypoints = pathPacket.waypoints
    local count = getDenseArrayLength(rawWaypoints, self.Config.maxTrackedWaypoints)

    if count == nil then
        return false, "InvalidWaypoints"
    end

    if count < 1 then
        return false, "EmptyWaypoints"
    end

    if count > self.Config.maxTrackedWaypoints then
        return false, "WaypointLimitExceeded"
    end

    -- Copy and validate the complete bounded route before issuing movement.
    local copied = table.create(count)

    for index = 1, count do
        local waypoint = rawget(rawWaypoints, index)

        if type(waypoint) ~= "table" or not isFiniteVector3(waypoint.position) then
            return false, "InvalidWaypointAtIndex" .. tostring(index)
        end

        local action = waypoint.action

        if action ~= nil
            and action ~= Enum.PathWaypointAction.Walk
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

    local humanoidOk, humanoid = pcall(function()
        return self.CharacterManager:GetHumanoid(character)
    end)

    local rootOk, root = pcall(function()
        return self.CharacterManager:GetRoot(character)
    end)

    local aliveOk, alive = pcall(function()
        return self.CharacterManager:IsAlive(character)
    end)

    if not humanoidOk or not rootOk or not aliveOk
        or not humanoid or not root or not alive then
        return false, "CharacterNotReady"
    end

    local readyOk, rootAnchored, seated, seatPart = pcall(function()
        return root.Anchored, humanoid.Sit, humanoid.SeatPart
    end)

    if not readyOk then
        return false, "CharacterStateUnavailable"
    end

    if rootAnchored then
        return false, "RootAnchored"
    end

    if seated or seatPart ~= nil then
        return false, "CharacterSeated"
    end

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

    local signalsOk, signalsReason = self:_connectMovementSignals(generation)

    if not signalsOk then
        self:_finish("Failed", signalsReason, false)
        return false, signalsReason
    end

    if self._destroyed
        or generation ~= self._generation
        or self._status ~= "Moving" then
        return false, "StoppedDuringInitialization"
    end

    local routeTimeoutOk, routeTimeoutReason = self:_scheduleRouteTimeout(generation)

    if not routeTimeoutOk then
        self:_finish("Failed", routeTimeoutReason, false)
        return false, routeTimeoutReason
    end

    self:_emit("Moving", "RouteStarted")

    if self._destroyed
        or generation ~= self._generation
        or self._status ~= "Moving" then
        return false, "StoppedDuringInitialization"
    end

    return self:_issueCurrentWaypoint(generation)
end

function MovementController:Stop(reason)
    if self._destroyed then
        return false, "Destroyed"
    end

    if self._status ~= "Moving" then
        return false, self._status
    end

    return self:_finish("Stopped", reason or "StoppedByCaller", true)
end

function MovementController:Destroy()
    if self._destroyed then
        return
    end

    -- Set this before emitting a final status so callbacks cannot restart movement.
    self._destroyed = true

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
    self._requestId = nil
    self._waypointIndex = 0

    self:_cancelSegmentTimeout()
    self:_cancelRouteTimeout()

    self._onStatus = nil
    self._status = "Destroyed"
    self._reason = "Destroyed"
end

return MovementController
