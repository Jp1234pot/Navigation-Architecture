
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
    probeSideScale = 0.55,
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
            assert(DEFAULT_OPTIONS[key] ~= nil, "Unknown EdgeJump option: " .. tostring(key))
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

local function isGrounded(humanoid, state)
    if state == Enum.HumanoidStateType.Jumping
        or state == Enum.HumanoidStateType.Freefall
        or state == Enum.HumanoidStateType.FallingDown
        or state == Enum.HumanoidStateType.Dead then
        return false
    end

    if GROUNDED_STATES[state] then
        return true
    end

    local ok, material = pcall(function()
        return humanoid.FloorMaterial
    end)

    return ok and material ~= Enum.Material.Air
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
        _attemptedAt = nil,

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
            warn("[Navigation v2.2] EdgeJump callback failed: " .. tostring(err))
        end
    end
end

function EdgeJump:SetOnStatus(callbackOrNil)
    if self._destroyed then
        return false, "Destroyed"
    end

    if callbackOrNil ~= nil and type(callbackOrNil) ~= "function" then
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

function EdgeJump:_evaluateEdge()
    local humanoid = self._humanoid
    local root = self._root

    local state = humanoid:GetState()

    if not isGrounded(humanoid, state) then
        return false
    end

    local movement = humanoid.MoveDirection
    local direction = Vector3.new(movement.X, 0, movement.Z)

    if direction.Magnitude < 0.05 then
        return false
    end

    direction = direction.Unit

    local rootRight = root.CFrame.RightVector
    local rootLook = root.CFrame.LookVector

    local sideDirection = Vector3.new(
        -direction.Z,
        0,
        direction.X
    )

    local sideExtent =
        math.abs(sideDirection:Dot(rootRight)) * root.Size.X * 0.5
        + math.abs(sideDirection:Dot(rootLook)) * root.Size.Z * 0.5

    -- Keep the forward probe close to the root center.
    -- Do not add the full root-part forward extent.
    local forwardOffset = self.Options.probeForwardExtra

    local sideOffset = math.max(
        0.1,
        sideExtent * self.Options.probeSideScale
    )

    local rayLength =
        humanoid.HipHeight
        + root.Size.Y * 0.5
        + self.Options.rayExtraDepth

    local centerSupported = self:_hasSupport(
        root.Position,
        rayLength
    )

    if not centerSupported then
        return false
    end

    local frontCenter =
        root.Position + direction * forwardOffset

    local frontLeft =
        frontCenter + sideDirection * sideOffset

    local frontRight =
        frontCenter - sideDirection * sideOffset

    local supportedCount = 0

    if self:_hasSupport(frontCenter, rayLength) then
        supportedCount += 1
    end

    if self:_hasSupport(frontLeft, rayLength) then
        supportedCount += 1
    end

    if self:_hasSupport(frontRight, rayLength) then
        supportedCount += 1
    end

    return supportedCount <= 1
end

function EdgeJump:_attemptPrimary()
    if not self._active or self._primaryAttempted then
        return false
    end

    self._primaryAttempted = true
    self._strategy = "Predictive"
    self._attemptedAt = os.clock()

    local ok, err = pcall(function()
        self._humanoid.Jump = true
    end)

    if not ok then
        self._reason = "PrimaryJumpRequestFailed: " .. tostring(err)
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
    self._attemptedAt = os.clock()

    local ok, err = pcall(function()
        self._humanoid:ChangeState(
            Enum.HumanoidStateType.Jumping
        )
    end)

    if not ok then
        self._reason = "FallbackJumpRequestFailed: " .. tostring(err)
    end

    return ok
end

function EdgeJump:_onStateChanged(_, newState)
    if not self._active or not self._attemptedAt then
        return
    end

    if newState == Enum.HumanoidStateType.Jumping then
        if os.clock() - self._attemptedAt
            <= self.Options.fallbackConfirmWindow then

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

    if state == Enum.HumanoidStateType.Jumping
        and self._attemptedAt
        and now - self._attemptedAt
            <= self.Options.fallbackConfirmWindow then

        self._jumpAccepted = true
        self:_finish("Succeeded", "JumpStateAccepted")
        return
    end

    -- Forum-inspired fallback:
    -- grounded -> Freefall without an accepted primary jump.
    if self._wasGrounded
        and state == Enum.HumanoidStateType.Freefall
        and not self._jumpAccepted
        and not self._fallbackAttempted then

        self:_attemptFallback()
    end

    self._wasGrounded = grounded

    if self._fallbackAttempted
        and self._attemptedAt
        and now - self._attemptedAt
            > self.Options.fallbackConfirmWindow then

        self:_finish("Failed", "BothJumpStrategiesUnaccepted")
        return
    end

    if now - self._startTime > self.Options.maxDuration then
        self:_finish("Failed", "EdgeNotReachedOrJumpUnaccepted")
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

    local humanoid = self.CharacterManager:GetHumanoid(character)
    local root = self.CharacterManager:GetRoot(character)

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
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = {character}

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
    self._strategy = nil
    self._lastFrameDelta = 0
    self._roundTripPing = nil

    -- Optional RTT telemetry. It does not delay local jump execution.
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
        self:_finish("Failed", "StateChangedConnectionFailed")
        return false, "StateChangedConnectionFailed"
    end

    if not connect(
        RunService.PreSimulation,
        function(deltaTimeSim)
            self:_onPreSimulation(deltaTimeSim)
        end
    ) then
        self:_finish("Failed", "PreSimulationConnectionFailed")
        return false, "PreSimulationConnectionFailed"
    end

    if not connect(
        RunService.Heartbeat,
        function()
            self:_onHeartbeat()
        end
    ) then
        self:_finish("Failed", "HeartbeatConnectionFailed")
        return false, "HeartbeatConnectionFailed"
    end

    if not connect(humanoid.Died, function()
        self:_finish("Stopped", "CharacterDied")
    end) then
        self:_finish("Failed", "DiedConnectionFailed")
        return false, "DiedConnectionFailed"
    end

    if not connect(character.AncestryChanged, function(_, parent)
        if parent == nil then
            self:_finish("Stopped", "CharacterRemoved")
        end
    end) then
        self:_finish("Failed", "AncestryConnectionFailed")
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

    return self:_finish("Stopped", reason or "StoppedByCaller")
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
