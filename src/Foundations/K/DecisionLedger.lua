
-- Navigation Architecture v2.2
-- Foundation K: DecisionLedger
-- Bounded, session-only explanation records. Records proposals; never executes them.

local DecisionLedger = {}
DecisionLedger.__index = DecisionLedger

local ALLOWED_TYPES = {
    RouteChoice = true,
    RepathEligibility = true,
    MovementGate = true,
    AnalysisSummary = true,
    ObservationInterpretation = true,
    ExperimentalComparison = true,
}

local function isFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function validText(value, maximum)
    return type(value) == "string" and #value >= 1 and #value <= maximum
end

local function copyStringArray(source, maximumCount, maximumLength)
    if source == nil then
        return {}, true
    end
    if type(source) ~= "table" then
        return nil, false
    end
    local result = {}
    local count = 0
    for key, value in pairs(source) do
        count += 1
        if count > maximumCount
            or type(key) ~= "number"
            or key % 1 ~= 0
            or key < 1
            or key > maximumCount
            or not validText(value, maximumLength) then
            return nil, false
        end
        result[key] = value
    end
    for index = 1, count do
        if result[index] == nil then
            return nil, false
        end
    end
    return result, true
end

function DecisionLedger.new(config)
    assert(type(config) == "table", "DecisionLedger requires validated config")
    local capacity = config.maxDecisionRecords
    assert(isFiniteNumber(capacity) and capacity % 1 == 0 and capacity >= 1 and capacity <= 256,
        "maxDecisionRecords must be an integer from 1 to 256")
    return setmetatable({
        Config = config,
        _capacity = capacity,
        _records = table.create(capacity),
        _nextIndex = 1,
        _count = 0,
        _destroyed = false,
    }, DecisionLedger)
end

-- Packet fields: decisionType, chosenOption, reason, alternatives, evidenceKeys,
-- confidenceScore (0-100), uncertainty (0-1), timestamp (optional).
function DecisionLedger:Record(packet)
    if self._destroyed then
        return false, "Destroyed"
    end
    if not self.Config.evidenceLedgerEnabled then
        return false, "Disabled"
    end
    if type(packet) ~= "table" then
        return false, "InvalidPacket"
    end
    if not ALLOWED_TYPES[packet.decisionType] then
        return false, "UnsupportedDecisionType"
    end
    if not validText(packet.chosenOption, 64) or not validText(packet.reason, 128) then
        return false, "InvalidDecisionText"
    end

    local alternatives, alternativesValid = copyStringArray(packet.alternatives, 8, 64)
    local evidenceKeys, evidenceValid = copyStringArray(packet.evidenceKeys, 8, 64)
    if not alternativesValid or not evidenceValid then
        return false, "InvalidList"
    end

    local confidenceScore = packet.confidenceScore
    if confidenceScore ~= nil and (not isFiniteNumber(confidenceScore)
        or confidenceScore < 0 or confidenceScore > 100) then
        return false, "InvalidConfidenceScore"
    end
    local uncertainty = packet.uncertainty
    if uncertainty ~= nil and (not isFiniteNumber(uncertainty) or uncertainty < 0 or uncertainty > 1) then
        return false, "InvalidUncertainty"
    end
    local timestamp = packet.timestamp or os.clock()
    if not isFiniteNumber(timestamp) or timestamp > os.clock() + 1 then
        return false, "InvalidTimestamp"
    end

    self._records[self._nextIndex] = {
        decisionType = packet.decisionType,
        chosenOption = packet.chosenOption,
        reason = packet.reason,
        alternatives = alternatives,
        evidenceKeys = evidenceKeys,
        confidenceScore = confidenceScore,
        uncertainty = uncertainty,
        timestamp = timestamp,
    }
    self._nextIndex = (self._nextIndex % self._capacity) + 1
    self._count = math.min(self._count + 1, self._capacity)
    return true, "Recorded"
end

function DecisionLedger:GetRecent(limit)
    if self._destroyed then
        return {}, "Destroyed"
    end
    local requested = limit or self._count
    if not isFiniteNumber(requested) or requested % 1 ~= 0 or requested < 0 then
        return {}, "InvalidLimit"
    end
    local amount = math.min(requested, self._count, self._capacity)
    local result = table.create(amount)
    local oldestIndex = ((self._nextIndex - self._count - 1) % self._capacity) + 1
    local skip = self._count - amount
    for offset = skip, self._count - 1 do
        local index = ((oldestIndex + offset - 1) % self._capacity) + 1
        local source = self._records[index]
        if source then
            result[#result + 1] = {
                decisionType = source.decisionType,
                chosenOption = source.chosenOption,
                reason = source.reason,
                alternatives = table.clone(source.alternatives),
                evidenceKeys = table.clone(source.evidenceKeys),
                confidenceScore = source.confidenceScore,
                uncertainty = source.uncertainty,
                timestamp = source.timestamp,
            }
        end
    end
    return result, "OK"
end

function DecisionLedger:GetSummary()
    if self._destroyed then
        return nil, "Destroyed"
    end
    return {
        storedRecords = self._count,
        capacity = self._capacity,
    }, "OK"
end

function DecisionLedger:Reset()
    if self._destroyed then
        return false, "Destroyed"
    end
    table.clear(self._records)
    self._nextIndex = 1
    self._count = 0
    return true, "Reset"
end

function DecisionLedger:Destroy()
    if self._destroyed then
        return
    end
    table.clear(self._records)
    self._nextIndex = 1
    self._count = 0
    self._destroyed = true
end

return DecisionLedger
