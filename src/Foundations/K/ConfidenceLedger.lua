
-- Navigation Architecture v2.2
-- Foundation K: ConfidenceLedger
-- Bounded, session-only evidence aggregation. No world access or automatic sampling.

local ConfidenceLedger = {}
ConfidenceLedger.__index = ConfidenceLedger

local ALLOWED_EVIDENCE = {
    PositionObservation = true,
    VelocityEstimate = true,
    Classification = true,
    PathObservation = true,
    StreamingObservation = true,
    RouteOutcome = true,
    GeometryObservation = true,
    ManualObservation = true,
}

local ALLOWED_POLARITY = {
    Supports = true,
    Contradicts = true,
    Neutral = true,
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

function ConfidenceLedger.new(config)
    assert(type(config) == "table", "ConfidenceLedger requires validated config")
    local capacity = config.maxEvidenceRecords
    assert(isFiniteNumber(capacity) and capacity % 1 == 0 and capacity >= 1 and capacity <= 512,
        "maxEvidenceRecords must be an integer from 1 to 512")
    assert(isFiniteNumber(config.evidenceMaxAge) and config.evidenceMaxAge > 0,
        "evidenceMaxAge must be finite and positive")
    assert(isFiniteNumber(config.evidenceHalfLife) and config.evidenceHalfLife > 0,
        "evidenceHalfLife must be finite and positive")
    assert(isFiniteNumber(config.evidenceMinSamples) and config.evidenceMinSamples % 1 == 0
        and config.evidenceMinSamples >= 1 and config.evidenceMinSamples <= 16,
        "evidenceMinSamples must be an integer from 1 to 16")

    return setmetatable({
        Config = config,
        _capacity = capacity,
        _records = table.create(capacity),
        _nextIndex = 1,
        _count = 0,
        _totalRecorded = 0,
        _destroyed = false,
    }, ConfidenceLedger)
end

-- subjectKey should be a short, non-identifying project key such as "LocalRoute"
-- or "Cell:4:-2". This module never stores Player names or user identifiers.
function ConfidenceLedger:Record(subjectKey, evidenceKind, polarity, quality, observedAt, note)
    if self._destroyed then
        return false, "Destroyed"
    end
    if not self.Config.evidenceLedgerEnabled then
        return false, "Disabled"
    end
    if not validText(subjectKey, 64) then
        return false, "InvalidSubjectKey"
    end
    if not ALLOWED_EVIDENCE[evidenceKind] then
        return false, "UnsupportedEvidenceKind"
    end
    if not ALLOWED_POLARITY[polarity] then
        return false, "InvalidPolarity"
    end
    if not isFiniteNumber(quality) or quality < 0 or quality > 1 then
        return false, "InvalidQuality"
    end

    local timestamp = observedAt
    if timestamp == nil then
        timestamp = os.clock()
    end
    if not isFiniteNumber(timestamp) then
        return false, "InvalidTimestamp"
    end
    if timestamp > os.clock() + 1 then
        return false, "FutureTimestamp"
    end
    if note ~= nil and (type(note) ~= "string" or #note > 96) then
        return false, "InvalidNote"
    end

    self._records[self._nextIndex] = {
        subjectKey = subjectKey,
        evidenceKind = evidenceKind,
        polarity = polarity,
        quality = quality,
        timestamp = timestamp,
        note = note or "",
    }
    self._nextIndex = (self._nextIndex % self._capacity) + 1
    self._count = math.min(self._count + 1, self._capacity)
    self._totalRecorded = math.min(self._totalRecorded + 1, 2147483647)
    return true, "Recorded"
end

-- Returns a confidence assessment, not a probability or guarantee.
function ConfidenceLedger:Assess(subjectKey, now)
    if self._destroyed then
        return nil, "Destroyed"
    end
    if not self.Config.evidenceLedgerEnabled then
        return nil, "Disabled"
    end
    if not validText(subjectKey, 64) then
        return nil, "InvalidSubjectKey"
    end
    local currentTime = now or os.clock()
    if not isFiniteNumber(currentTime) then
        return nil, "InvalidTimestamp"
    end

    local supportingWeight = 0
    local contradictingWeight = 0
    local neutralWeight = 0
    local effectiveSamples = 0
    local freshestAge = nil
    local kindCounts = {}

    local oldestIndex = ((self._nextIndex - self._count - 1) % self._capacity) + 1
    for offset = 0, self._count - 1 do
        local index = ((oldestIndex + offset - 1) % self._capacity) + 1
        local record = self._records[index]
        if record and record.subjectKey == subjectKey then
            local age = currentTime - record.timestamp
            if age >= 0 and age <= self.Config.evidenceMaxAge then
                local freshness = 2 ^ (-age / self.Config.evidenceHalfLife)
                local weight = record.quality * freshness
                if weight > 0 then
                    effectiveSamples += 1
                    kindCounts[record.evidenceKind] = (kindCounts[record.evidenceKind] or 0) + 1
                    freshestAge = freshestAge and math.min(freshestAge, age) or age
                    if record.polarity == "Supports" then
                        supportingWeight += weight
                    elseif record.polarity == "Contradicts" then
                        contradictingWeight += weight
                    else
                        neutralWeight += weight
                    end
                end
            end
        end
    end

    local directionalWeight = supportingWeight + contradictingWeight
    local direction = "Unknown"
    local score = 0
    if directionalWeight > 0 then
        if supportingWeight > contradictingWeight then
            direction = "Supports"
        elseif contradictingWeight > supportingWeight then
            direction = "Contradicts"
        else
            direction = "Inconclusive"
        end
        local agreement = math.abs(supportingWeight - contradictingWeight) / directionalWeight
        local coverage = math.min(1, effectiveSamples / self.Config.evidenceMinSamples)
        score = math.floor(agreement * coverage * 100 + 0.5)
    end

    local status = "Unknown"
    if direction ~= "Unknown" and score >= 75 then
        status = "High"
    elseif direction ~= "Unknown" and score >= 40 then
        status = "Moderate"
    elseif direction ~= "Unknown" then
        status = "Low"
    end

    return {
        subjectKey = subjectKey,
        direction = direction,
        confidenceScore = score,
        status = status,
        effectiveSamples = effectiveSamples,
        supportingWeight = supportingWeight,
        contradictingWeight = contradictingWeight,
        neutralWeight = neutralWeight,
        freshestEvidenceAge = freshestAge,
        evidenceKinds = kindCounts,
        isProbability = false,
    }, "OK"
end

function ConfidenceLedger:GetRecent(limit)
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
                subjectKey = source.subjectKey,
                evidenceKind = source.evidenceKind,
                polarity = source.polarity,
                quality = source.quality,
                timestamp = source.timestamp,
                note = source.note,
            }
        end
    end
    return result, "OK"
end

function ConfidenceLedger:GetSummary()
    if self._destroyed then
        return nil, "Destroyed"
    end
    return {
        storedRecords = self._count,
        capacity = self._capacity,
        totalRecorded = self._totalRecorded,
    }, "OK"
end

function ConfidenceLedger:Reset()
    if self._destroyed then
        return false, "Destroyed"
    end
    table.clear(self._records)
    self._nextIndex = 1
    self._count = 0
    self._totalRecorded = 0
    return true, "Reset"
end

function ConfidenceLedger:Destroy()
    if self._destroyed then
        return
    end
    table.clear(self._records)
    self._count = 0
    self._nextIndex = 1
    self._destroyed = true
end

return ConfidenceLedger
