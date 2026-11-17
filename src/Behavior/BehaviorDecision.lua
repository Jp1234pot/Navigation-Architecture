

-- Navigation Architecture v2.2
-- Module: BehaviorDecision
-- Behavior layer: interprets eligible multi-contact analysis.
--
-- Responsibilities:
--   - Select the configured Pursue or Escape intent.
--   - Preserve multiple simultaneous contact assessments.
--   - Produce a bounded, explainable behavior proposal.
--   - Identify a priority candidate for subsequent route evaluation.
--
-- This module does NOT:
--   - Discover or classify targets.
--   - Infer hostile intent from proximity alone.
--   - Compute routes or movement directions.
--   - Execute movement or traversal techniques.
--   - Interact with server remotes.

local BehaviorDecision = {}
BehaviorDecision.__index = BehaviorDecision

local VALID_MODES = {
    Pursue = true,
    Escape = true,
}

local VALID_ASSESSMENTS = {
    CriticalProximity = true,
    PredictedCriticalPass = true,
    ElevatedProximity = true,
    PredictedNearPass = true,
    Approaching = true,
    Distant = true,
}

local function isFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
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

local function copyContact(contact)
    return {
        model = contact.model,
        player = contact.player,
        kind = contact.kind,
        classification = contact.classification,
        distance = contact.distance,
        closingSpeed = contact.closingSpeed,
        timeToClosestApproach = contact.timeToClosestApproach,
        predictedClosestDistance = contact.predictedClosestDistance,
        velocityAvailable = contact.velocityAvailable,
        score = contact.score,
        assessment = contact.assessment,
        sampleTimestamp = contact.sampleTimestamp,
    }
end

local function copyDecision(decision)
    if not decision then
        return nil
    end

    local result = {
        status = decision.status,
        reason = decision.reason,
        mode = decision.mode,
        timestamp = decision.timestamp,
        analysisTimestamp = decision.analysisTimestamp,
        targetMode = decision.targetMode,
        partialAnalysis = decision.partialAnalysis,
        inspectedCount = decision.inspectedCount,
        uninspectedCount = decision.uninspectedCount,
        rejectedCount = decision.rejectedCount,
        requiresRouteEvaluation = decision.requiresRouteEvaluation,
        priorityCandidate = nil,
        contacts = {},
    }

    if decision.priorityCandidate then
        result.priorityCandidate = copyContact(
            decision.priorityCandidate
        )
    end

    for index, contact in ipairs(decision.contacts) do
        result.contacts[index] = copyContact(contact)
    end

    return result
end

local function validateContact(contact, expectedMode)
    if type(contact) ~= "table" then
        return false
    end

    if not isModel(contact.model) then
        return false
    end

    if not contact.model:IsDescendantOf(workspace) then
        return false
    end

    if contact.kind ~= expectedMode then
        return false
    end

    if not isFiniteNumber(contact.distance)
        or contact.distance < 0 then
        return false
    end

    if not isFiniteNumber(contact.score)
        or contact.score < 0
        or contact.score > 100 then
        return false
    end

    if not VALID_ASSESSMENTS[contact.assessment] then
        return false
    end

    if contact.closingSpeed ~= nil
        and not isFiniteNumber(contact.closingSpeed) then
        return false
    end

    if contact.predictedClosestDistance ~= nil
        and (
            not isFiniteNumber(contact.predictedClosestDistance)
            or contact.predictedClosestDistance < 0
        ) then
        return false
    end

    if contact.timeToClosestApproach ~= nil
        and (
            not isFiniteNumber(contact.timeToClosestApproach)
            or contact.timeToClosestApproach < 0
        ) then
        return false
    end

    return true
end

local function sortContacts(contacts)
    table.sort(contacts, function(left, right)
        if left.score ~= right.score then
            return left.score > right.score
        end

        if left.distance ~= right.distance then
            return left.distance < right.distance
        end

        local leftPredicted =
            left.predictedClosestDistance or math.huge

        local rightPredicted =
            right.predictedClosestDistance or math.huge

        return leftPredicted < rightPredicted
    end)
end

function BehaviorDecision.new(config, options)
    assert(
        type(config) == "table",
        "BehaviorDecision requires validated config"
    )

    assert(
        VALID_MODES[config.behaviorMode],
        "Invalid behaviorMode"
    )

    assert(
        config.targetMode == "Player"
            or config.targetMode == "NPC",
        "Invalid targetMode"
    )

    options = options or {}

    assert(
        type(options) == "table",
        "BehaviorDecision options must be a table"
    )

    local maxAnalysisAge =
        options.maxAnalysisAge
        or config.threatMaxEstimateAge
        or 0.75

    local maxContacts =
        options.maxContacts
        or config.maxThreatResults
        or 16

    assert(
        isFiniteNumber(maxAnalysisAge)
            and maxAnalysisAge > 0,
        "maxAnalysisAge must be positive"
    )

    assert(
        isFiniteNumber(maxContacts)
            and maxContacts % 1 == 0
            and maxContacts >= 1
            and maxContacts <= 64,
        "maxContacts must be an integer from 1 to 64"
    )

    return setmetatable({
        Config = config,

        _mode = config.behaviorMode,
        _targetMode = config.targetMode,

        _maxAnalysisAge = maxAnalysisAge,
        _maxContacts = maxContacts,

        _latest = nil,
        _destroyed = false,
    }, BehaviorDecision)
end

function BehaviorDecision:SetMode(mode)
    if self._destroyed then
        return false, "Destroyed"
    end

    if not VALID_MODES[mode] then
        return false, "InvalidBehaviorMode"
    end

    self._mode = mode
    self._latest = nil

    return true, "ModeUpdated"
end

function BehaviorDecision:GetMode()
    if self._destroyed then
        return nil, "Destroyed"
    end

    return self._mode, "OK"
end

function BehaviorDecision:_makeUnavailable(reason, packet)
    local decision = {
        status = "Waiting",
        reason = reason,
        mode = self._mode,
        timestamp = os.clock(),
        analysisTimestamp =
            type(packet) == "table" and packet.timestamp or nil,
        targetMode = self._targetMode,
        partialAnalysis = true,
        inspectedCount = 0,
        uninspectedCount = 0,
        rejectedCount = 0,
        requiresRouteEvaluation = false,
        priorityCandidate = nil,
        contacts = {},
    }

    self._latest = decision

    return copyDecision(decision), reason
end

function BehaviorDecision:Evaluate(packet)
    if self._destroyed then
        return nil, "Destroyed"
    end

    if self.Config.enabled ~= true then
        return self:_makeUnavailable(
            "NavigationDisabled",
            packet
        )
    end

    if self.Config.multiThreatAnalysisEnabled ~= true then
        return self:_makeUnavailable(
            "ThreatAnalysisDisabled",
            packet
        )
    end

    if type(packet) ~= "table" then
        return self:_makeUnavailable(
            "AnalysisPacketUnavailable",
            nil
        )
    end

    if packet.targetMode ~= self._targetMode then
        return self:_makeUnavailable(
            "TargetModeMismatch",
            packet
        )
    end

    if not isFiniteNumber(packet.timestamp) then
        return self:_makeUnavailable(
            "InvalidAnalysisTimestamp",
            packet
        )
    end

    local now = os.clock()
    local analysisAge = now - packet.timestamp

    if analysisAge < 0
        or analysisAge > self._maxAnalysisAge then
        return self:_makeUnavailable(
            "AnalysisStale",
            packet
        )
    end

    if type(packet.results) ~= "table" then
        return self:_makeUnavailable(
            "InvalidAnalysisResults",
            packet
        )
    end

    local contacts = {}
    local rejectedCount = 0

    for index = 1, math.min(#packet.results, self._maxContacts) do
        local contact = packet.results[index]

        if validateContact(contact, self._targetMode) then
            contacts[#contacts + 1] = copyContact(contact)
        else
            rejectedCount += 1
        end
    end

    sortContacts(contacts)

    local inspectedCount =
        packet.inspectedSourceEntries or 0

    local uninspectedCount =
        packet.uninspectedSourceEntries or 0

    local sourceRejectedCount =
        packet.rejectedCount or 0

    if not isFiniteNumber(inspectedCount)
        or inspectedCount < 0
        or not isFiniteNumber(uninspectedCount)
        or uninspectedCount < 0
        or not isFiniteNumber(sourceRejectedCount)
        or sourceRejectedCount < 0 then
        return self:_makeUnavailable(
            "InvalidAnalysisCoverage",
            packet
        )
    end

    local partialAnalysis =
        uninspectedCount > 0
        or sourceRejectedCount > 0
        or rejectedCount > 0

    local priorityCandidate = contacts[1]

    local status
    local reason

    if not priorityCandidate then
        status = "NoObservedContacts"
        reason = partialAnalysis
            and "NoValidContactsInPartialAnalysis"
            or "NoValidContactsInAnalysis"
    else
        status = "ProposalReady"

        if self._mode == "Pursue" then
            reason = "PriorityEligibleCandidateIdentified"
        else
            reason = "PriorityContactAndThreatSetIdentified"
        end
    end

    local decision = {
        status = status,
        reason = reason,

        mode = self._mode,
        timestamp = now,
        analysisTimestamp = packet.timestamp,
        targetMode = self._targetMode,

        partialAnalysis = partialAnalysis,
        inspectedCount = inspectedCount,
        uninspectedCount = uninspectedCount,
        rejectedCount = rejectedCount + sourceRejectedCount,

        -- A route evaluator must still assess reachability,
        -- obstacles, movement feasibility, and current conditions.
        requiresRouteEvaluation =
            priorityCandidate ~= nil,

        priorityCandidate = priorityCandidate,
        contacts = contacts,
    }

    self._latest = decision

    return copyDecision(decision), "OK"
end

function BehaviorDecision:GetLatest()
    if self._destroyed then
        return nil, "Destroyed"
    end

    if not self._latest then
        return nil, "NoDecisionAvailable"
    end

    return copyDecision(self._latest), "OK"
end

function BehaviorDecision:Reset()
    if self._destroyed then
        return false, "Destroyed"
    end

    self._latest = nil

    return true, "Reset"
end

function BehaviorDecision:Destroy()
    if self._destroyed then
        return
    end

    self._latest = nil
    self.Config = nil
    self._destroyed = true
end

return BehaviorDecision
