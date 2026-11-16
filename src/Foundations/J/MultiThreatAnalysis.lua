
-- Navigation Architecture v2.2
-- Foundation J: MultiThreatAnalysis
-- Client-only, read-only, bounded proximity and trajectory assessment.
-- This module does not infer intent, select an action, highlight, move, or attack.

local MultiThreatAnalysis = {}
MultiThreatAnalysis.__index = MultiThreatAnalysis

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

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function getFreshVelocity(estimate, snapshotTimestamp, maxAge)
    if type(estimate) ~= "table"
        or not isFiniteVector3(estimate.velocity)
        or not isFiniteNumber(estimate.timestamp)
        or not isFiniteNumber(snapshotTimestamp) then
        return nil
    end

    local age = math.abs(snapshotTimestamp - estimate.timestamp)
    if age > maxAge then
        return nil
    end

    return estimate.velocity
end

local function assessContact(localPosition, localVelocity, localTimestamp, candidate, snapshot, estimate, config)
    if type(candidate) ~= "table"
        or typeof(candidate.model) ~= "Instance"
        or not candidate.model:IsA("Model")
        or (candidate.kind ~= "Player" and candidate.kind ~= "NPC") then
        return nil, "InvalidCandidate"
    end

    if type(snapshot) ~= "table"
        or snapshot.model ~= candidate.model
        or not isFiniteVector3(snapshot.position)
        or not isFiniteNumber(snapshot.timestamp) then
        return nil, "InvalidSnapshot"
    end
    if math.abs(snapshot.timestamp - localTimestamp) > config.threatMaxEstimateAge then
        return nil, "SnapshotSkewTooLarge"
    end

    local offset = snapshot.position - localPosition
    local distance = offset.Magnitude
    if not isFiniteNumber(distance) then
        return nil, "InvalidDistance"
    end

    local candidateVelocity = getFreshVelocity(estimate, snapshot.timestamp, config.threatMaxEstimateAge)
    local hasRelativeVelocity = localVelocity ~= nil and candidateVelocity ~= nil
    local closingSpeed = nil
    local timeToClosestApproach = nil
    local predictedClosestDistance = nil

    if hasRelativeVelocity then
        local relativeVelocity = candidateVelocity - localVelocity
        local relativeSpeedSquared = relativeVelocity:Dot(relativeVelocity)
        if isFiniteNumber(relativeSpeedSquared) and relativeSpeedSquared > 0.0001 then
            local closingRate = -offset:Dot(relativeVelocity) / math.max(distance, 0.001)
            if isFiniteNumber(closingRate) then
                closingSpeed = closingRate
            end

            local time = -offset:Dot(relativeVelocity) / relativeSpeedSquared
            if isFiniteNumber(time) and time > 0 and time <= config.threatPredictionHorizon then
                local closestOffset = offset + relativeVelocity * time
                local closestDistance = closestOffset.Magnitude
                if isFiniteNumber(closestDistance) then
                    timeToClosestApproach = time
                    predictedClosestDistance = closestDistance
                end
            end
        else
            closingSpeed = 0
        end
    end

    local proximityScore = clamp(1 - (distance / config.threatNearDistance), 0, 1) * 60
    local approachScore = 0
    if closingSpeed and closingSpeed > 0 then
        approachScore = clamp(closingSpeed / config.threatMaxApproachSpeed, 0, 1) * 25
    end

    local trajectoryScore = 0
    if predictedClosestDistance then
        trajectoryScore = clamp(
            1 - (predictedClosestDistance / config.threatNearDistance),
            0,
            1
        ) * 15
    end

    local score = math.floor(clamp(proximityScore + approachScore + trajectoryScore, 0, 100) + 0.5)
    local assessment
    if distance <= config.threatCriticalDistance then
        assessment = "CriticalProximity"
    elseif predictedClosestDistance ~= nil
        and predictedClosestDistance <= config.threatCriticalDistance then
        assessment = "PredictedCriticalPass"
    elseif distance <= config.threatNearDistance then
        assessment = "ElevatedProximity"
    elseif predictedClosestDistance ~= nil
        and predictedClosestDistance <= config.threatNearDistance then
        assessment = "PredictedNearPass"
    elseif closingSpeed ~= nil and closingSpeed >= 2 then
        assessment = "Approaching"
    else
        assessment = "Distant"
    end

    return {
        model = candidate.model,
        player = candidate.player,
        kind = candidate.kind,
        classification = candidate.classification or "Unclassified",
        distance = distance,
        closingSpeed = closingSpeed,
        timeToClosestApproach = timeToClosestApproach,
        predictedClosestDistance = predictedClosestDistance,
        velocityAvailable = hasRelativeVelocity,
        score = score,
        assessment = assessment,
        sampleTimestamp = snapshot.timestamp,
    }, "OK"
end

function MultiThreatAnalysis.new(dependencies)
    assert(type(dependencies) == "table", "MultiThreatAnalysis requires dependencies")

    local config = dependencies.config
    local targetDiscovery = dependencies.targetDiscovery
    local physicsObserver = dependencies.physicsObserver
    local velocityEstimator = dependencies.velocityEstimator

    assert(type(config) == "table", "MultiThreatAnalysis requires validated config")
    assert(targetDiscovery ~= nil, "MultiThreatAnalysis requires TargetDiscovery")
    assert(physicsObserver ~= nil, "MultiThreatAnalysis requires PhysicsObserver")
    assert(velocityEstimator ~= nil, "MultiThreatAnalysis requires a dedicated VelocityEstimator")
    assert(type(config.maxThreatCandidates) == "number"
        and config.maxThreatCandidates % 1 == 0
        and config.maxThreatCandidates >= 1
        and config.maxThreatCandidates <= 64,
        "maxThreatCandidates must be an integer from 1 to 64")
    assert(type(config.maxThreatResults) == "number"
        and config.maxThreatResults % 1 == 0
        and config.maxThreatResults >= 1
        and config.maxThreatResults <= config.maxThreatCandidates,
        "maxThreatResults must be an integer from 1 to maxThreatCandidates")

    return setmetatable({
        Config = config,
        TargetDiscovery = targetDiscovery,
        PhysicsObserver = physicsObserver,
        VelocityEstimator = velocityEstimator,
        RecoveryAnalysis = dependencies.recoveryAnalysis,
        _nextStartIndex = {
            Player = 1,
            NPC = 1,
        },
        _lastAnalysisAt = nil,
        _destroyed = false,
    }, MultiThreatAnalysis)
end

-- Analyze performs one bounded batch. It does not create a connection, timer,
-- task, or repeating loop. Candidate scanning rotates between batches so a
-- capped scan does not permanently favor the first entries in the source list.
function MultiThreatAnalysis:Analyze(localRecord)
    if self._destroyed then
        return nil, "Destroyed"
    end
    if not self.Config.multiThreatAnalysisEnabled then
        return nil, "Disabled"
    end

    local localSnapshot = type(localRecord) == "table" and localRecord.snapshot or nil
    if type(localSnapshot) ~= "table"
        or not isFiniteVector3(localSnapshot.position)
        or not isFiniteNumber(localSnapshot.timestamp) then
        return nil, "LocalSnapshotUnavailable"
    end

    local now = os.clock()
    if self._lastAnalysisAt
        and now - self._lastAnalysisAt < self.Config.threatAnalysisMinInterval then
        return nil, "RateLimited"
    end
    self._lastAnalysisAt = now

    local localVelocity = getFreshVelocity(
        type(localRecord) == "table" and localRecord.estimate or nil,
        localSnapshot.timestamp,
        self.Config.threatMaxEstimateAge
    )

    local mode = self.Config.targetMode
    local startIndex = self._nextStartIndex[mode] or 1
    local candidates, discoveryStatus, inspectedCount, sourceCount, rotationWindowCount =
        self.TargetDiscovery:GetCandidates(
            mode,
            localSnapshot.position,
            self.Config.maxThreatCandidates,
            startIndex
        )

    if discoveryStatus ~= "OK" then
        return nil, discoveryStatus
    end

    inspectedCount = inspectedCount or #candidates
    sourceCount = sourceCount or inspectedCount
    rotationWindowCount = rotationWindowCount or sourceCount
    if rotationWindowCount > 0 then
        self._nextStartIndex[mode] = ((startIndex - 1 + math.max(inspectedCount, 1)) % rotationWindowCount) + 1
    else
        self._nextStartIndex[mode] = 1
    end

    local results = {}
    local rejectedCount = 0
    local nearestDistance = nil

    -- candidates is already capped by TargetDiscovery; this loop cannot exceed 64.
    for index = 1, math.min(#candidates, self.Config.maxThreatCandidates) do
        local candidate = candidates[index]
        local currentOk, isCurrent = pcall(function()
            return self.TargetDiscovery:IsCandidateCurrent(candidate, mode)
        end)

        if currentOk and isCurrent then
            local snapshot = self.PhysicsObserver:ObservePosition(candidate.model)
            if snapshot then
                local estimate = self.VelocityEstimator:Update(snapshot)
                if not estimate then
                    estimate = self.VelocityEstimator:GetEstimate(candidate.model)
                end

                local result = assessContact(
                    localSnapshot.position,
                    localVelocity,
                    localSnapshot.timestamp,
                    candidate,
                    snapshot,
                    estimate,
                    self.Config
                )

                if result then
                    result.velocityAvailable = result.velocityAvailable == true
                    result._inputOrder = index
                    results[#results + 1] = result
                    nearestDistance = nearestDistance and math.min(nearestDistance, result.distance)
                        or result.distance
                else
                    rejectedCount += 1
                    self.VelocityEstimator:Reset(candidate.model)
                end
            else
                rejectedCount += 1
                self.VelocityEstimator:Reset(candidate.model)
            end
        else
            rejectedCount += 1
            if candidate and candidate.model then
                self.VelocityEstimator:Reset(candidate.model)
            end
        end
    end

    table.sort(results, function(left, right)
        if left.score == right.score then
            if left.distance == right.distance then
                return left._inputOrder < right._inputOrder
            end
            return left.distance < right.distance
        end
        return left.score > right.score
    end)

    local analyzedCount = #results
    local returnedCount = math.min(analyzedCount, self.Config.maxThreatResults)
    for index = analyzedCount, returnedCount + 1, -1 do
        results[index] = nil
    end
    for index = 1, returnedCount do
        results[index]._inputOrder = nil
    end

    local packet = {
        timestamp = os.clock(),
        targetMode = mode,
        inspectedSourceEntries = inspectedCount,
        sourceEntriesAvailable = sourceCount,
        discoveryWindowEntries = rotationWindowCount,
        uninspectedSourceEntries = math.max(sourceCount - inspectedCount, 0),
        uninspectedWithinDiscoveryWindow = math.max(rotationWindowCount - inspectedCount, 0),
        analyzedCount = analyzedCount,
        rejectedCount = rejectedCount,
        returnedCount = returnedCount,
        nearestDistance = nearestDistance,
        highestAssessment = results[1] and results[1].assessment or "None",
        results = results,
        velocityNote = "Velocity uses fresh position-derived estimates; raw AssemblyLinearVelocity is not used for remote candidates.",
        authorityNote = "Client-side observation only; not authoritative game state.",
    }

    if self.RecoveryAnalysis then
        self.RecoveryAnalysis:Record("ThreatAnalysis", "BatchCompleted", analyzedCount)
    end

    return packet, "OK"
end

function MultiThreatAnalysis:Destroy()
    if self._destroyed then
        return
    end
    self._nextStartIndex.Player = 1
    self._nextStartIndex.NPC = 1
    self._lastAnalysisAt = nil
    self._destroyed = true
end

return MultiThreatAnalysis
