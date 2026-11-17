-- Navigation Architecture v2.2
-- Module: BehaviorRouteCoordinator
-- Behavior layer: bounded handoff from a behavior proposal to route services.
--
-- Responsibilities:
--   - Validate a BehaviorDecision proposal.
--   - Resolve a Pursue destination from the selected candidate.
--   - Require an externally evaluated destination for Escape.
--   - Request a path through Foundation F.
--   - Hand successful paths to Foundation G.
--   - Optionally start Foundation H when movement is explicitly enabled.
--
-- This module does NOT:
--   - Discover or classify candidates.
--   - Decide whether a candidate is hostile.
--   - Select safe Escape destinations.
--   - Implement advanced traversal techniques.
--   - Access server remotes or server-only data.
--
-- Integration contract:
--   The owner of PathfindingEngine must forward its SetOnResult
--   packets to BehaviorRouteCoordinator:AcceptPathResult(packet).

local BehaviorRouteCoordinator = {}
BehaviorRouteCoordinator.__index = BehaviorRouteCoordinator

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

local function isModel(value)
    if typeof(value) ~= "Instance" then
        return false
    end

    local ok, result = pcall(function()
        return value:IsA("Model")
    end)

    return ok and result == true
end

local function hasMethods(value, methods)
    if type(value) ~= "table" then
        return false
    end

    for _, methodName in ipairs(methods) do
        local ok, method = pcall(function()
            return value[methodName]
        end)

        if not ok or type(method) ~= "function" then
            return false
        end
    end

    return true
end

local function getModelRoot(model)
    if not isModel(model) then
        return nil
    end

    local ok, root = pcall(function()
        local humanoidRoot = model:FindFirstChild("HumanoidRootPart")

        if humanoidRoot and humanoidRoot:IsA("BasePart") then
            return humanoidRoot
        end

        local primary = model.PrimaryPart

        if primary and primary:IsA("BasePart") then
            return primary
        end

        local torso = model:FindFirstChild("Torso")

        if torso and torso:IsA("BasePart") then
            return torso
        end

        return nil
    end)

    return ok and root or nil
end

function BehaviorRouteCoordinator.new(config, dependencies, options)
    assert(type(config) == "table",
        "BehaviorRouteCoordinator requires config")

    assert(type(dependencies) == "table",
        "BehaviorRouteCoordinator requires dependencies")

    assert(
        hasMethods(dependencies.pathfindingEngine, {
            "RequestPath", "Cancel",
        }),
        "A compatible PathfindingEngine is required"
    )

    assert(
        hasMethods(dependencies.waypointTracker, {
            "SetPath", "Update", "GetProgress", "Reset",
        }),
        "A compatible WaypointTracker is required"
    )

    assert(
        hasMethods(dependencies.characterManager, {
            "GetCharacter", "GetRoot",
        }),
        "A compatible CharacterManager is required"
    )

    local movementController = dependencies.movementController

    assert(
        movementController == nil
            or hasMethods(movementController, {
                "Start", "Stop", "GetStatus",
            }),
        "movementController must be compatible or nil"
    )

    options = options or {}

    assert(type(options) == "table",
        "options must be a table")

    local maxDecisionAge =
        options.maxDecisionAge
        or config.threatMaxEstimateAge
        or 0.75

    assert(
        isFiniteNumber(maxDecisionAge)
            and maxDecisionAge > 0,
        "maxDecisionAge must be positive"
    )

    return setmetatable({
        Config = config,

        PathfindingEngine = dependencies.pathfindingEngine,
        WaypointTracker = dependencies.waypointTracker,
        CharacterManager = dependencies.characterManager,
        MovementController = movementController,

        _maxDecisionAge = maxDecisionAge,

        _status = "Idle",
        _reason = "NotStarted",
        _requestId = nil,
        _mode = nil,
        _destination = nil,

        _requesting = false,
        _earlyPacket = nil,

        _onStatus = nil,
        _destroyed = false,
    }, BehaviorRouteCoordinator)
end

function BehaviorRouteCoordinator:_emit(status, reason, extra)
    self._status = status
    self._reason = reason or status

    local callback = self._onStatus

    if callback then
        local packet = {
            status = status,
            reason = self._reason,
            requestId = self._requestId,
            mode = self._mode,
            destination = self._destination,
            timestamp = os.clock(),
        }

        if type(extra) == "table" then
            for key, value in pairs(extra) do
                packet[key] = value
            end
        end

        local ok, err = pcall(callback, packet)

        if not ok then
            warn(
                "[Navigation v2.2] BehaviorRouteCoordinator "
                .. "status callback failed: "
                .. tostring(err)
            )
        end
    end
end

function BehaviorRouteCoordinator:SetOnStatus(callbackOrNil)
    if self._destroyed then
        return false, "Destroyed"
    end

    if callbackOrNil ~= nil
        and type(callbackOrNil) ~= "function" then
        return false, "CallbackMustBeFunctionOrNil"
    end

    self._onStatus = callbackOrNil

    return true, "OK"
end

function BehaviorRouteCoordinator:GetStatus()
    if self._destroyed then
        return {
            status = "Destroyed",
            reason = "Destroyed",
        }
    end

    return {
        status = self._status,
        reason = self._reason,
        requestId = self._requestId,
        mode = self._mode,
        destination = self._destination,
    }
end

function BehaviorRouteCoordinator:_resolveDestination(
    decision,
    escapeDestination
)
    if decision.mode == "Escape" then
        if not isFiniteVector3(escapeDestination) then
            return nil, "EscapeDestinationRequired"
        end

        return escapeDestination, "OK"
    end

    if decision.mode ~= "Pursue" then
        return nil, "UnsupportedBehaviorMode"
    end

    local candidate = decision.priorityCandidate

    if type(candidate) ~= "table"
        or candidate.kind ~= self.Config.targetMode
        or not isModel(candidate.model) then
        return nil, "InvalidPriorityCandidate"
    end

    local model = candidate.model

    local currentOk, current = pcall(function()
        return model:IsDescendantOf(workspace)
    end)

    if not currentOk or not current then
        return nil, "PriorityCandidateUnavailable"
    end

    local root = getModelRoot(model)

    if not root then
        return nil, "PriorityCandidateRootUnavailable"
    end

    local positionOk, position = pcall(function()
        return root.Position
    end)

    if not positionOk or not isFiniteVector3(position) then
        return nil, "PriorityCandidatePositionUnavailable"
    end

    return position, "OK"
end

function BehaviorRouteCoordinator:RequestRoute(
    decision,
    escapeDestination
)
    if self._destroyed then
        return false, nil, "Destroyed"
    end

    if self.Config.enabled ~= true then
        return false, nil, "NavigationDisabled"
    end

    if self.Config.pathfindingEnabled ~= true then
        return false, nil, "PathfindingDisabled"
    end

    if self._status == "Computing"
        or self._status == "RouteReady"
        or self._status == "Moving" then
        return false, nil, "RouteAlreadyActive"
    end

    if type(decision) ~= "table"
        or decision.status ~= "ProposalReady"
        or decision.requiresRouteEvaluation ~= true then
        return false, nil, "DecisionNotRouteReady"
    end

    if decision.mode ~= "Pursue"
        and decision.mode ~= "Escape" then
        return false, nil, "InvalidBehaviorMode"
    end

    if decision.targetMode ~= self.Config.targetMode then
        return false, nil, "TargetModeMismatch"
    end

    if not isFiniteNumber(decision.timestamp) then
        return false, nil, "InvalidDecisionTimestamp"
    end

    local decisionAge = os.clock() - decision.timestamp

    if decisionAge < 0
        or decisionAge > self._maxDecisionAge then
        return false, nil, "DecisionStale"
    end

    local destination, destinationReason =
        self:_resolveDestination(decision, escapeDestination)

    if not destination then
        return false, nil, destinationReason
    end

    local characterOk, character = pcall(function()
        return self.CharacterManager:GetCharacter()
    end)

    if not characterOk or not isModel(character) then
        return false, nil, "LocalCharacterUnavailable"
    end

    local rootOk, root = pcall(function()
        return self.CharacterManager:GetRoot(character)
    end)

    if not rootOk or not root then
        return false, nil, "LocalRootUnavailable"
    end

    local positionOk, startPosition = pcall(function()
        return root.Position
    end)

    if not positionOk or not isFiniteVector3(startPosition) then
        return false, nil, "LocalPositionUnavailable"
    end

    self.WaypointTracker:Reset("NewRouteRequest")

    self._mode = decision.mode
    self._destination = destination
    self._requestId = nil
    self._requesting = true
    self._earlyPacket = nil
    
    -- Fix 1: Track internal requesting/submitting state
    self._status = "Requesting"
    self._reason = "SubmittingPathRequest"

    local requestOk, requestId, requestReason =
        self.PathfindingEngine:RequestPath(
            startPosition,
            destination
        )

    self._requesting = false

    if not requestOk then
        self._earlyPacket = nil
        self._requestId = nil

        self:_emit("Rejected", requestReason)

        return false, nil, requestReason
    end

    self._requestId = requestId

    -- Fix 2: Conditional emission once request ID is bound
    if self._status == "Requesting" then
        self:_emit("Computing", "PathRequestAccepted")
    end

    local earlyPacket = self._earlyPacket
    self._earlyPacket = nil

    if earlyPacket
        and earlyPacket.requestId == requestId then
        self:AcceptPathResult(earlyPacket)
    end

    return true, requestId, requestReason
end

function BehaviorRouteCoordinator:_processPathResult(pathPacket)
    if pathPacket.status == "Computing" then
        return true, "Computing"
    end

    if pathPacket.status ~= "Success" then
        self:_emit(
            "PathFailed",
            pathPacket.status or "PathComputationFailed",
            {
                detail = pathPacket.detail,
            }
        )

        return false, "PathComputationFailed"
    end

    local accepted, trackerReason =
        self.WaypointTracker:SetPath(pathPacket)

    if not accepted then
        self:_emit("PathRejected", trackerReason)
        return false, trackerReason
    end

    if self.Config.movementEnabled ~= true then
        self:_emit("RouteReady", "MovementDisabled")
        return true, "RouteReady"
    end

    if not self.MovementController then
        self:_emit(
            "RouteReady",
            "MovementControllerUnavailable"
        )

        return true, "RouteReady"
    end

    local characterOk, character = pcall(function()
        return self.CharacterManager:GetCharacter()
    end)

    if not characterOk or not character then
        self:_emit(
            "RouteReady",
            "LocalCharacterUnavailable"
        )

        return false, "LocalCharacterUnavailable"
    end

    local started, startReason =
        self.MovementController:Start(character, pathPacket)

    if not started then
        self:_emit(
            "RouteReady",
            "MovementStartRejected:" .. tostring(startReason)
        )

        return false, startReason
    end

    self:_emit("Moving", "MovementStarted")

    return true, "Moving"
end

function BehaviorRouteCoordinator:AcceptPathResult(pathPacket)
    if self._destroyed then
        return false, "Destroyed"
    end

    if type(pathPacket) ~= "table"
        or not isFiniteNumber(pathPacket.requestId)
        or type(pathPacket.status) ~= "string" then
        return false, "InvalidPathPacket"
    end

    -- RequestPath publishes its initial Computing packet before
    -- returning the request ID. Handle that synchronous callback.
    if self._requesting and self._requestId == nil then
        if pathPacket.status == "Computing" then
            self._requestId = pathPacket.requestId
            -- Fix 3: Handle early computing status update properly
            self:_emit("Computing", "PathComputationInProgress")
            return true, "Computing"
        end

        self._earlyPacket = pathPacket
        return true, "Buffered"
    end

    if pathPacket.requestId ~= self._requestId then
        return false, "StalePathResult"
    end

    return self:_processPathResult(pathPacket)
end

function BehaviorRouteCoordinator:UpdateProgress()
    if self._destroyed then
        return nil, "Destroyed"
    end

    if self._status ~= "RouteReady"
        and self._status ~= "Moving" then
        return nil, "NoActiveRoute"
    end

    local characterOk, character = pcall(function()
        return self.CharacterManager:GetCharacter()
    end)

    if not characterOk or not character then
        return nil, "LocalCharacterUnavailable"
    end

    local rootOk, root = pcall(function()
        return self.CharacterManager:GetRoot(character)
    end)

    if not rootOk or not root then
        return nil, "LocalRootUnavailable"
    end

    local positionOk, position = pcall(function()
        return root.Position
    end)

    if not positionOk or not isFiniteVector3(position) then
        return nil, "LocalPositionUnavailable"
    end

    local progress, reason =
        self.WaypointTracker:Update(position)

    if not progress then
        return nil, reason
    end

    if progress.status == "Completed" then
        self:_emit("Completed", "AllWaypointsReached", {
            progress = progress.progress,
        })
    end

    return progress, "OK"
end

function BehaviorRouteCoordinator:Cancel(reason)
    if self._destroyed then
        return false, "Destroyed"
    end

    if self._status ~= "Computing"
        and self._status ~= "RouteReady"
        and self._status ~= "Moving" then
        return false, "NoActiveRoute"
    end

    if self._status == "Moving"
        and self.MovementController then
        pcall(function()
            self.MovementController:Stop(
                reason or "RouteCancelled"
            )
        end)
    end

    if self._status == "Computing" then
        pcall(function()
            self.PathfindingEngine:Cancel(
                reason or "RouteCancelled"
            )
        end)
    end

    self.WaypointTracker:Reset(
        reason or "RouteCancelled"
    )

    self._requestId = nil
    self._destination = nil
    self._mode = nil
    self._earlyPacket = nil

    self:_emit(
        "Cancelled",
        reason or "RouteCancelled"
    )

    return true, "Cancelled"
end

function BehaviorRouteCoordinator:Destroy()
    if self._destroyed then
        return
    end

    if self._status == "Moving"
        or self._status == "Computing" then
        self:Cancel("CoordinatorDestroyed")
    end

    self._onStatus = nil
    self._requestId = nil
    self._destination = nil
    self._mode = nil
    self._earlyPacket = nil

    self.Config = nil
    self.PathfindingEngine = nil
    self.WaypointTracker = nil
    self.CharacterManager = nil
    self.MovementController = nil

    self._destroyed = true
    self._status = "Destroyed"
    self._reason = "Destroyed"
end

return BehaviorRouteCoordinator
