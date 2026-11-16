
-- Navigation Architecture v2.2
-- Module: AdaptiveRepath
-- Foundation I: event-driven repath eligibility with strict cooldown and budget limits.
-- This module does not compute paths, move characters, poll, or create timers.

local AdaptiveRepath = {}
AdaptiveRepath.__index = AdaptiveRepath

local VALID_REASONS = {
    TargetMoved = true,
    PathBlockedAhead = true,
    MovementFailed = true,
    RouteInvalidated = true,
    ScheduledRefresh = true,
}

local function isFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

function AdaptiveRepath.new(config, recoveryAnalysis)
    assert(type(config) == "table", "AdaptiveRepath requires validated config")
    assert(isFiniteNumber(config.adaptiveRepathMinInterval)
        and config.adaptiveRepathMinInterval > 0 and config.adaptiveRepathMinInterval <= 30,
        "adaptiveRepathMinInterval must be finite and within (0, 30]")
    assert(isFiniteNumber(config.adaptiveRepathWindowSeconds)
        and config.adaptiveRepathWindowSeconds >= 10 and config.adaptiveRepathWindowSeconds <= 600,
        "adaptiveRepathWindowSeconds must be within 10-600")
    assert(isFiniteNumber(config.adaptiveRepathMaxRequestsPerWindow)
        and config.adaptiveRepathMaxRequestsPerWindow % 1 == 0
        and config.adaptiveRepathMaxRequestsPerWindow >= 1
        and config.adaptiveRepathMaxRequestsPerWindow <= 30,
        "adaptiveRepathMaxRequestsPerWindow must be an integer from 1 to 30")
    assert(isFiniteNumber(config.adaptiveRepathMaxBackoff)
        and config.adaptiveRepathMaxBackoff >= config.adaptiveRepathMinInterval
        and config.adaptiveRepathMaxBackoff <= 120,
        "adaptiveRepathMaxBackoff must be >= min interval and <= 120")
    assert(isFiniteNumber(config.adaptiveRepathTargetDistance)
        and config.adaptiveRepathTargetDistance >= 1 and config.adaptiveRepathTargetDistance <= 100,
        "adaptiveRepathTargetDistance must be within 1-100")
    assert(isFiniteNumber(config.adaptiveRepathCircuitBreakAfter)
        and config.adaptiveRepathCircuitBreakAfter % 1 == 0
        and config.adaptiveRepathCircuitBreakAfter >= 1
        and config.adaptiveRepathCircuitBreakAfter <= 10,
        "adaptiveRepathCircuitBreakAfter must be an integer from 1 to 10")
    assert(isFiniteNumber(config.adaptiveRepathCircuitBreakSeconds)
        and config.adaptiveRepathCircuitBreakSeconds >= 1
        and config.adaptiveRepathCircuitBreakSeconds <= 300,
        "adaptiveRepathCircuitBreakSeconds must be within 1-300")

    return setmetatable({
        Config = config,
        RecoveryAnalysis = recoveryAnalysis,
        _windowStartedAt = os.clock(),
        _requestsInWindow = 0,
        _lastRequestAt = nil,
        _consecutiveFailures = 0,
        _circuitOpenUntil = nil,
        _lastDecision = "NotEvaluated",
        _destroyed = false,
    }, AdaptiveRepath)
end

function AdaptiveRepath:_record(kind, reason, value)
    if self.RecoveryAnalysis then
        self.RecoveryAnalysis:Record(kind, reason, value)
    end
end

function AdaptiveRepath:_refreshWindow(now)
    if now < self._windowStartedAt or now - self._windowStartedAt >= self.Config.adaptiveRepathWindowSeconds then
        self._windowStartedAt = now
        self._requestsInWindow = 0
    end
end

function AdaptiveRepath:_expireCircuit(now)
    if self._circuitOpenUntil and now >= self._circuitOpenUntil then
        self._circuitOpenUntil = nil
        self._consecutiveFailures = 0
        self:_record("CircuitBreaker", "CircuitClosed", 0)
    end
end

function AdaptiveRepath:Consider(reason, context)
    if self._destroyed then
        return false, "Destroyed"
    end
    if self.Config.adaptiveRepathEnabled ~= true then
        self._lastDecision = "Disabled"
        return false, "Disabled"
    end
    if not VALID_REASONS[reason] then
        return false, "UnsupportedReason"
    end

    context = context or {}
    if type(context) ~= "table" then
        return false, "InvalidContext"
    end

    if reason == "TargetMoved" then
        if not isFiniteNumber(context.targetDisplacement) then
            return false, "TargetDisplacementRequired"
        end
        if context.targetDisplacement < self.Config.adaptiveRepathTargetDistance then
            self._lastDecision = "TargetMovementBelowThreshold"
            self:_record("RepathDecision", self._lastDecision, context.targetDisplacement)
            return false, self._lastDecision
        end
    elseif reason == "PathBlockedAhead" then
        local blocked = context.blockedWaypointIndex
        local current = context.currentWaypointIndex
        if not isFiniteNumber(blocked) or not isFiniteNumber(current)
            or blocked % 1 ~= 0 or current % 1 ~= 0 or blocked < 1 or current < 1 then
            return false, "WaypointIndicesRequired"
        end
        if blocked < current then
            self._lastDecision = "BlockedWaypointBehindAgent"
            self:_record("RepathDecision", self._lastDecision, blocked)
            return false, self._lastDecision
        end
    elseif reason == "MovementFailed" then
        if context.movementStatus ~= "Failed" then
            return false, "MovementFailureNotConfirmed"
        end
    end

    local now = os.clock()
    self:_expireCircuit(now)
    if self._circuitOpenUntil and now < self._circuitOpenUntil then
        self._lastDecision = "CircuitOpen"
        self:_record("RepathDecision", self._lastDecision, self._circuitOpenUntil - now)
        return false, self._lastDecision
    end

    self:_refreshWindow(now)
    if self._requestsInWindow >= self.Config.adaptiveRepathMaxRequestsPerWindow then
        self._lastDecision = "RequestBudgetExhausted"
        self:_record("RepathDecision", self._lastDecision, self._requestsInWindow)
        return false, self._lastDecision
    end

    local exponent = math.min(self._consecutiveFailures, 8)
    local cooldown = math.min(
        self.Config.adaptiveRepathMaxBackoff,
        self.Config.adaptiveRepathMinInterval * (2 ^ exponent)
    )
    if self._lastRequestAt and now - self._lastRequestAt < cooldown then
        self._lastDecision = "Cooldown"
        self:_record("RepathDecision", self._lastDecision, cooldown - (now - self._lastRequestAt))
        return false, self._lastDecision
    end

    self._requestsInWindow += 1
    self._lastRequestAt = now
    self._lastDecision = "Eligible"
    self:_record("RepathDecision", "Eligible:" .. reason, self._requestsInWindow)

    return true, {
        reason = reason,
        authorizedAt = now,
        requestsInWindow = self._requestsInWindow,
        remainingBudget = self.Config.adaptiveRepathMaxRequestsPerWindow - self._requestsInWindow,
        consecutiveFailures = self._consecutiveFailures,
    }
end

function AdaptiveRepath:ReportOutcome(success, reason, recordKind)
    if self._destroyed then
        return false, "Destroyed"
    end
    if type(success) ~= "boolean" then
        return false, "SuccessMustBeBoolean"
    end
    reason = reason or (success and "PathSucceeded" or "PathFailed")
    recordKind = recordKind or "PathResult"
    if type(reason) ~= "string" or #reason == 0 or #reason > 96 then
        return false, "InvalidReason"
    end
    if recordKind ~= "PathResult" and recordKind ~= "MovementResult" then
        return false, "InvalidRecordKind"
    end

    if success then
        self._consecutiveFailures = 0
        self._circuitOpenUntil = nil
        self:_record(recordKind, reason, 1)
        return true, "FailureCounterReset"
    end

    self._consecutiveFailures = math.min(self._consecutiveFailures + 1, 1000)
    self:_record(recordKind, reason, self._consecutiveFailures)

    if self._consecutiveFailures >= self.Config.adaptiveRepathCircuitBreakAfter
        and not self._circuitOpenUntil then
        self._circuitOpenUntil = os.clock() + self.Config.adaptiveRepathCircuitBreakSeconds
        self:_record("CircuitBreaker", "CircuitOpened", self.Config.adaptiveRepathCircuitBreakSeconds)
    end
    return true, "FailureRecorded"
end

function AdaptiveRepath:GetState()
    if self._destroyed then
        return nil, "Destroyed"
    end
    local now = os.clock()
    self:_expireCircuit(now)
    self:_refreshWindow(now)
    return {
        enabled = self.Config.adaptiveRepathEnabled == true,
        requestsInWindow = self._requestsInWindow,
        maxRequestsPerWindow = self.Config.adaptiveRepathMaxRequestsPerWindow,
        consecutiveFailures = self._consecutiveFailures,
        circuitOpen = self._circuitOpenUntil ~= nil and now < self._circuitOpenUntil,
        circuitRemaining = self._circuitOpenUntil and math.max(0, self._circuitOpenUntil - now) or 0,
        lastDecision = self._lastDecision,
        lastRequestAt = self._lastRequestAt,
    }, "OK"
end

function AdaptiveRepath:Reset(reason)
    if self._destroyed then
        return false, "Destroyed"
    end
    reason = reason or "Reset"
    if type(reason) ~= "string" or #reason == 0 or #reason > 64 then
        return false, "InvalidReason"
    end
    self._windowStartedAt = os.clock()
    self._requestsInWindow = 0
    self._lastRequestAt = nil
    self._consecutiveFailures = 0
    self._circuitOpenUntil = nil
    self._lastDecision = reason
    self:_record("RepathDecision", "Reset:" .. self._lastDecision, 0)
    return true, "Reset"
end

function AdaptiveRepath:Destroy()
    if self._destroyed then
        return
    end
    self._circuitOpenUntil = nil
    self._lastRequestAt = nil
    self._requestsInWindow = 0
    self._consecutiveFailures = 0
    self.RecoveryAnalysis = nil
    self._destroyed = true
end

return AdaptiveRepath
