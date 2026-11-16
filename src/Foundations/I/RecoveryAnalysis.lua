
-- Navigation Architecture v2.2
-- Module: RecoveryAnalysis
-- Foundation I: bounded session-only recovery event history.
-- Stores compact diagnostic records only; no polling, timers, or world access.

local RecoveryAnalysis = {}
RecoveryAnalysis.__index = RecoveryAnalysis

local ALLOWED_KINDS = {
    PathResult = true,
    MovementResult = true,
    BlockedEvent = true,
    RepathDecision = true,
    CircuitBreaker = true,
    RequestRejected = true,
    ThreatAnalysis = true,
}

local function isFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

function RecoveryAnalysis.new(config)
    assert(type(config) == "table", "RecoveryAnalysis requires validated config")
    local capacity = config.maxRecoveryRecords
    assert(isFiniteNumber(capacity) and capacity % 1 == 0 and capacity >= 1 and capacity <= 1000,
        "maxRecoveryRecords must be an integer from 1 to 1000")

    return setmetatable({
        Config = config,
        _capacity = capacity,
        _records = table.create(capacity),
        _nextIndex = 1,
        _count = 0,
        _totals = {
            PathResult = 0,
            MovementResult = 0,
            BlockedEvent = 0,
            RepathDecision = 0,
            CircuitBreaker = 0,
            RequestRejected = 0,
            ThreatAnalysis = 0,
        },
        _destroyed = false,
    }, RecoveryAnalysis)
end

function RecoveryAnalysis:Record(kind, reason, numericValue)
    if self._destroyed then
        return false, "Destroyed"
    end
    if not ALLOWED_KINDS[kind] then
        return false, "UnsupportedRecordKind"
    end
    if type(reason) ~= "string" or #reason == 0 or #reason > 96 then
        return false, "InvalidReason"
    end
    if numericValue ~= nil and not isFiniteNumber(numericValue) then
        return false, "InvalidNumericValue"
    end

    local record = {
        kind = kind,
        reason = reason,
        value = numericValue,
        timestamp = os.clock(),
    }

    self._records[self._nextIndex] = record
    self._nextIndex = (self._nextIndex % self._capacity) + 1
    self._count = math.min(self._count + 1, self._capacity)
    self._totals[kind] = math.min(self._totals[kind] + 1, 2147483647)
    return true, "Recorded"
end

function RecoveryAnalysis:GetRecent(limit)
    if self._destroyed then
        return {}, "Destroyed"
    end
    if limit == nil then
        limit = self._count
    end
    if not isFiniteNumber(limit) or limit % 1 ~= 0 or limit < 0 then
        return {}, "InvalidLimit"
    end

    local amount = math.min(limit, self._count, self._capacity)
    local result = table.create(amount)
    local oldestIndex = ((self._nextIndex - self._count - 1) % self._capacity) + 1
    local skip = self._count - amount
    for offset = skip, self._count - 1 do
        local index = ((oldestIndex + offset - 1) % self._capacity) + 1
        local source = self._records[index]
        if source then
            result[#result + 1] = {
                kind = source.kind,
                reason = source.reason,
                value = source.value,
                timestamp = source.timestamp,
            }
        end
    end
    return result, "OK"
end

function RecoveryAnalysis:GetSummary()
    if self._destroyed then
        return nil, "Destroyed"
    end
    local totals = {}
    for kind, count in pairs(self._totals) do
        totals[kind] = count
    end
    return {
        storedRecords = self._count,
        capacity = self._capacity,
        totals = totals,
    }, "OK"
end

function RecoveryAnalysis:Reset()
    if self._destroyed then
        return false, "Destroyed"
    end
    table.clear(self._records)
    self._nextIndex = 1
    self._count = 0
    for kind in pairs(self._totals) do
        self._totals[kind] = 0
    end
    return true, "Reset"
end

function RecoveryAnalysis:Destroy()
    if self._destroyed then
        return
    end
    table.clear(self._records)
    table.clear(self._totals)
    self._count = 0
    self._nextIndex = 1
    self._destroyed = true
end

return RecoveryAnalysis
