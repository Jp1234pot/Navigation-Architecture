
-- Navigation Architecture v2.2
-- Foundation H: EdgeJump
-- Primary: predictive support-boundary detection.
-- Fallback: reactive grounded-to-Freefall transition.
--
-- This module only handles the EdgeJump technique.
-- It does not select targets, calculate paths, or control behavior modes.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local EdgeJump = {}
EdgeJump.__index = EdgeJump

local GROUNDED_STATES = {
    [Enum.HumanoidStateType.Running] = true,
    [Enum.HumanoidStateType.RunningNoPhysics] = true,
    [Enum.HumanoidStateType.Landed] = true,
}

local DEFAULT_OPTIONS = {
    cooldown = 0.25,
    probeForwardExtra = 0.05,
    rayExtraDepth = 1.5,
    maxFrameDelta = 0.10,
    maxDuration = 2.5,
    fallbackConfirmWindow = 0.40,
    fallbackEnabled = true,
}

local function isFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function isModel(value)
    return typeof(value) == "Instance"
        and value:IsA("Model")
end

local function disconnect(connection)
    if connection then
        pcall(function()
            connection:Disconnect()
        end)
    end
end

local function copyOptions(options)
    local result = table.clone(DEFAULT_OPTIONS)

    if options ~= nil then
        assert(type(options) == "table", "Options must be a table")

        for key, value in pairs(options) do
            assert(
                DEFAULT_OPTIONS[key] ~= nil,
                "Unknown EdgeJump option: " .. tostring(key)
            )

            result[key] = value
        end
    end

    for key, defaultValue in pairs(DEFAULT_OPTIONS) do
        if type(defaultValue) == "number" then
            assert(
                isFiniteNumber(result[key]) and result[key] > 0,
                "Invalid EdgeJump option: " .. key
            )
        else
            assert(
                type(result[key]) == "boolean",
                "Invalid EdgeJump option: " .. key
            )
        end
    end

    return result
end

-- Only explicit grounded locomotion states qualify.
-- FloorMaterial alone is not reliable enough to classify every state.
local function isGrounded(_, state)
    return GROUNDED_STATES[state] == true
end

function EdgeJump.new(config, characterManager, options)
    assert(type(config) == "table", "EdgeJump requires validated config")
    assert(characterManager ~= nil, "EdgeJump requires CharacterManager")

    return setmetatable({
        Config = config,
        CharacterManager = characterManager,
        Options = copyOptions(options),

        _status = "Idle",
        _reason = "Initialized",
        _strategy = nil,

        _character = nil,
        _humanoid = nil,
        _root = nil,
        _raycastParams = nil,

        _connections = {},

        _active = false,
        _destroyed = false,

        _startTime = 0,
        _lastStartTime = 0,

        -- Primary and fallback attempts have separate timestamps.
        _attemptedAt = nil,
        _edgeCandidateAt = nil,
        _fallbackAttemptedAt = nil,

        _wasGrounded = false,
        _primaryAttempted = false,
        _fallbackAttempted = false,
        _jumpAccepted = false,

        _lastFrameDelta = 0,
        _roundTripPing = nil,

        _onStatus = nil,
    }, EdgeJump)
end

function EdgeJump:_emit(status, reason)
    self._status = status
    self._reason = reason or status

    if self._onStatus then
        local ok, err = pcall(self._onStatus, {
            status = self._status,
            reason = self._reason,
            strategy = self._strategy,
            primaryAttempted = self._primaryAttempted,
            fallbackAttempted = self._fallbackAttempted,
            jumpAccepted = self._jumpAccepted,
            roundTripPing = self._roundTripPing,
            frameDelta = self._lastFrameDelta,
            timestamp = os.clock(),
        })

        if not ok then
            warn(
                "[Navigation v2.2] EdgeJump callback failed: "
                .. tostring(err)
            )
        end
    end
end

function EdgeJump:SetOnStatus(callbackOrNil)
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

function EdgeJump:GetStatus()
    return {
        status = self._status,
        reason = self._reason,
        strategy = self._strategy,
        active = self._active,
        primaryAttempted = self._primaryAttempted,
        fallbackAttempted = self._fallbackAttempted,
        jumpAccepted = self._jumpAccepted,
        roundTripPing = self._roundTripPing,
        frameDelta = self._lastFrameDelta,
    }
end

function EdgeJump:_disconnect()
    for _, connection in ipairs(self._connections) do
        disconnect(connection)
    end

    table.clear(self._connections)
end

function EdgeJump:_finish(status, reason)
    if not self._active then
        return false, self._status
    end

    self._active = false
    self:_disconnect()

    self:_emit(status, reason)

    self._character = nil
    self._humanoid = nil
    self._root = nil
    self._raycastParams = nil

    return status == "Succeeded", status
end

function EdgeJump:_isCharacterCurrent()
    local character = self._character
    local humanoid = self._humanoid
    local root = self._root

    if not isModel(character)
        or not humanoid
        or not root then
        return false, "CharacterUnavailable"
    end

    local ok, currentCharacter = pcall(function()
        return self.CharacterManager:GetCharacter()
    end)

    if not ok or currentCharacter ~= character then
        return false, "CharacterChanged"
    end

    if not character:IsDescendantOf(Workspace)
        or not humanoid:IsDescendantOf(character)
        or not root:IsDescendantOf(character) then
        return false, "CharacterRemoved"
    end

    if humanoid.Health <= 0 then
        return false, "CharacterDead"
    end

    if root.Anchored or humanoid.Sit or humanoid.SeatPart ~= nil then
        return false, "CharacterUnavailable"
    end

    return true, "OK"
end

function EdgeJump:_hasSupport(position, rayLength)
    local origin = position + Vector3.new(0, 0.5, 0)
    local direction = Vector3.new(0, -rayLength, 0)

    local ok, result = pcall(function()
        return Workspace:Raycast(
            origin,
            direction,
            self._raycastParams
        )
    end)

    return ok and result ~= nil
end

-- Predictive edge detection.
--
-- Requirement:
-- 1. The character's root center still has support.
-- 2. A small distance ahead in the movement direction has no support.
--
-- This deliberately removes the side probes. On narrow platforms,
-- side probes can be unsupported even when the forward path is safe.
function EdgeJump:_evaluateEdge()
    local humanoid = self._humanoid
    local root = self._root

    if not isGrounded(humanoid, humanoid:GetState()) then
        return false
    end

    local movement = humanoid.MoveDirection
    local direction = Vector3.new(
        movement.X,
        0,
        movement.Z
    )

    if direction.Magnitude < 0.05 then
        return false
    end

    direction = direction.Unit

    local rayLength =
        humanoid.HipHeight
        + root.Size.Y * 0.5
        + self.Options.rayExtraDepth

    -- The root center must still be supported.
    local centerSupported = self:_hasSupport(
        root.Position,
        rayLength
    )

    if not centerSupported then
        return false
    end

    -- Check support slightly ahead of the root center.
    local forwardPosition =
        root.Position
        + direction * self.Options.probeForwardExtra

    return not self:_hasSupport(
        forwardPosition,
        rayLength
    )
end

function EdgeJump:_attemptPrimary()
    if not self._active or self._primaryAttempted then
        return false
    end

    self._primaryAttempted = true
    self._strategy = "Predictive"
    self._attemptedAt = os.clock()

    -- Preserve the first edge-candidate timestamp.
    self._edgeCandidateAt =
        self._edgeCandidateAt or self._attemptedAt

    local ok, err = pcall(function()
        self._humanoid.Jump = true
    end)

    if not ok then
        self._reason =
            "PrimaryJumpRequestFailed: " .. tostring(err)
    end

    return ok
end

function EdgeJump:_attemptFallback()
    if not self._active
        or self._fallbackAttempted
        or not self.Options.fallbackEnabled then
        return false
    end

    self._fallbackAttempted = true
    self._strategy = "ReactiveFallback"

    -- Do not overwrite the primary attempt timestamp.
    self._fallbackAttemptedAt = os.clock()

    local ok, err = pcall(function()
        self._humanoid:ChangeState(
            Enum.HumanoidStateType.Jumping
        )
    end)

    if not ok then
        self._reason =
            "FallbackJumpRequestFailed: " .. tostring(err)
    end

    return ok
end

function EdgeJump:_onStateChanged(_, newState)
    if not self._active then
        return
    end

    if newState == Enum.HumanoidStateType.Jumping then
        local now = os.clock()

        local primaryRecent =
            self._attemptedAt ~= nil
            and now - self._attemptedAt
                <= self.Options.fallbackConfirmWindow

        local fallbackRecent =
            self._fallbackAttemptedAt ~= nil
            and now - self._fallbackAttemptedAt
                <= self.Options.fallbackConfirmWindow

        if primaryRecent or fallbackRecent then
            self._jumpAccepted = true
            self:_finish("Succeeded", "JumpStateAccepted")
        end
    end
end

function EdgeJump:_onPreSimulation(deltaTimeSim)
    if not self._active then
        return
    end

    self._lastFrameDelta = deltaTimeSim

    -- Avoid making a predictive decision on a large frame spike.
    if deltaTimeSim > self.Options.maxFrameDelta then
        return
    end

    if self._primaryAttempted then
        return
    end

    local usable, reason = self:_isCharacterCurrent()

    if not usable then
        self:_finish("Failed", reason)
        return
    end

    local ok, edgeDetected = pcall(function()
        return self:_evaluateEdge()
    end)

    if ok and edgeDetected then
        self._edgeCandidateAt = os.clock()
        self:_attemptPrimary()
    end
end

function EdgeJump:_onHeartbeat()
    if not self._active then
        return
    end

    local usable, reason = self:_isCharacterCurrent()

    if not usable then
        self:_finish("Stopped", reason)
        return
    end

    local humanoid = self._humanoid
    local state = humanoid:GetState()
    local grounded = isGrounded(humanoid, state)
    local now = os.clock()

    -- Confirm whether either jump request was accepted.
    if state == Enum.HumanoidStateType.Jumping then
        local primaryRecent =
            self._attemptedAt ~= nil
            and now - self._attemptedAt
                <= self.Options.fallbackConfirmWindow

        local fallbackRecent =
            self._fallbackAttemptedAt ~= nil
            and now - self._fallbackAttemptedAt
                <= self.Options.fallbackConfirmWindow

        if primaryRecent or fallbackRecent then
            self._jumpAccepted = true
            self:_finish("Succeeded", "JumpStateAccepted")
            return
        end
    end

    -- The fallback is only armed by a recently detected edge.
    -- It cannot trigger simply because the character walks off
    -- an unrelated platform or ledge.
    local candidateRecent =
        self._edgeCandidateAt ~= nil
        and now - self._edgeCandidateAt
            <= self.Options.fallbackConfirmWindow

    if self._wasGrounded
        and state == Enum.HumanoidStateType.Freefall
        and candidateRecent
        and not self._jumpAccepted
        and not self._fallbackAttempted then

        self:_attemptFallback()
    end

    self._wasGrounded = grounded

    -- Give the fallback its own confirmation window.
    if self._fallbackAttempted
        and self._fallbackAttemptedAt
        and now - self._fallbackAttemptedAt
            > self.Options.fallbackConfirmWindow then

        self:_finish(
            "Failed",
            "BothJumpStrategiesUnaccepted"
        )

        return
    end

    if now - self._startTime > self.Options.maxDuration then
        self:_finish(
            "Failed",
            "EdgeNotReachedOrJumpUnaccepted"
        )
    end
end

function EdgeJump:Start(character)
    if self._destroyed then
        return false, "Destroyed"
    end

    if self._active then
        return false, "AlreadyRunning"
    end

    if self.Config.enabled ~= true then
        return false, "NavigationDisabled"
    end

    if self.Config.movementEnabled ~= true then
        return false, "MovementDisabled"
    end

    if self.Config.agentCanJump ~= true then
        return false, "JumpDisabled"
    end

    local now = os.clock()

    if self._lastStartTime > 0
        and now - self._lastStartTime < self.Options.cooldown then
        return false, "Cooldown"
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

    local humanoid =
        self.CharacterManager:GetHumanoid(character)

    local root =
        self.CharacterManager:GetRoot(character)

    if not humanoid or not root
        or humanoid.Health <= 0
        or root.Anchored
        or humanoid.Sit
        or humanoid.SeatPart ~= nil then
        return false, "CharacterNotReady"
    end

    local state = humanoid:GetState()

    if not isGrounded(humanoid, state) then
        return false, "NotGrounded"
    end

    local jumpEnabled = humanoid:GetStateEnabled(
        Enum.HumanoidStateType.Jumping
    )

    if not jumpEnabled then
        return false, "JumpStateDisabled"
    end

    local params = RaycastParams.new()
params.ExcludeInstances = {character}

    pcall(function()
        params.RespectCanCollide = true
    end)

    self._character = character
    self._humanoid = humanoid
    self._root = root
    self._raycastParams = params

    self._active = true
    self._startTime = now
    self._lastStartTime = now

    self._wasGrounded = true
    self._primaryAttempted = false
    self._fallbackAttempted = false
    self._jumpAccepted = false

    self._attemptedAt = nil
    self._edgeCandidateAt = nil
    self._fallbackAttemptedAt = nil

    self._strategy = nil
    self._lastFrameDelta = 0
    self._roundTripPing = nil

    -- Optional RTT telemetry.
    -- It does not delay local jump execution.
    local localPlayer = Players.LocalPlayer

    if localPlayer then
        local pingOk, ping = pcall(function()
            return localPlayer:GetNetworkPing()
        end)

        if pingOk and isFiniteNumber(ping) and ping >= 0 then
            self._roundTripPing = ping
        end
    end

    local function connect(signal, callback)
        local ok, connection = pcall(function()
            return signal:Connect(callback)
        end)

        if not ok or not connection then
            return false
        end

        table.insert(self._connections, connection)
        return true
    end

    if not connect(
        humanoid.StateChanged,
        function(oldState, newState)
            self:_onStateChanged(oldState, newState)
        end
    ) then
        self:_finish(
            "Failed",
            "StateChangedConnectionFailed"
        )

        return false, "StateChangedConnectionFailed"
    end

    if not connect(
        RunService.PreSimulation,
        function(deltaTimeSim)
            self:_onPreSimulation(deltaTimeSim)
        end
    ) then
        self:_finish(
            "Failed",
            "PreSimulationConnectionFailed"
        )

        return false, "PreSimulationConnectionFailed"
    end

    if not connect(
        RunService.Heartbeat,
        function()
            self:_onHeartbeat()
        end
    ) then
        self:_finish(
            "Failed",
            "HeartbeatConnectionFailed"
        )

        return false, "HeartbeatConnectionFailed"
    end

    if not connect(humanoid.Died, function()
        self:_finish("Stopped", "CharacterDied")
    end) then
        self:_finish(
            "Failed",
            "DiedConnectionFailed"
        )

        return false, "DiedConnectionFailed"
    end

    if not connect(character.AncestryChanged, function(_, parent)
        if parent == nil then
            self:_finish("Stopped", "CharacterRemoved")
        end
    end) then
        self:_finish(
            "Failed",
            "AncestryConnectionFailed"
        )

        return false, "AncestryConnectionFailed"
    end

    self:_emit("Running", "MonitoringEdge")
    return true, "Running"
end

function EdgeJump:Stop(reason)
    if self._destroyed then
        return false, "Destroyed"
    end

    if not self._active then
        return false, self._status
    end

    return self:_finish(
        "Stopped",
        reason or "StoppedByCaller"
    )
end

function EdgeJump:Destroy()
    if self._destroyed then
        return
    end

    if self._active then
        self:_finish("Stopped", "Destroyed")
    else
        self:_disconnect()
    end

    self._destroyed = true
    self._onStatus = nil

    self._character = nil
    self._humanoid = nil
    self._root = nil
    self._raycastParams = nil

    self._status = "Destroyed"
    self._reason = "Destroyed"
end

return EdgeJump
