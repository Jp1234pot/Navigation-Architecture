-- Navigation Architecture v2.2
-- Behavior module: EscapeDestinationEvaluator
--
-- Responsibilities:
--   - Evaluate caller-supplied arena destination candidates.
--   - Compare each candidate against every observed contact.
--   - Require supplied reachability and movement-feasibility approval.
--   - Prefer destinations with better minimum separation.
--   - Account for route cost and observation uncertainty.
--   - Preserve partial-analysis limitations in the result.
--
-- This module does NOT:
--   - Scan the world or generate arena geometry.
--   - Assume that unobserved space is safe.
--   - Infer hostile intent.
--   - Guarantee collision-free movement.
--   - Execute movement or request paths.
--
-- Candidate input contract:
-- {
--     id = "Surface_01",
--     position = Vector3,
--     routeCandidateAvailable = true,
--     routeIsHypothetical = true,
--     requiresPhysicalValidation = true,
--     feasibility = "WithinConfiguredEnvelope",
--     uncertainty = 0.0,       -- optional, 0 to 1
--     routeCost = 10.0,        -- optional, non-negative
--     observedAt = os.clock(), -- optional, timestamp
-- }
--
-- Candidates must be normalized by an adapter using actual
-- Arena Analysis outputs. This module does not assume undocumented
-- L1-L5 result fields.

local EscapeDestinationEvaluator = {}
EscapeDestinationEvaluator.__index = EscapeDestinationEvaluator

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

local function getRootPosition(model)
    if not isModel(model) then
        return nil
    end

    local ok, position = pcall(function()
        local root = model:FindFirstChild("HumanoidRootPart")

        if not root or not root:IsA("BasePart") then
            root = model.PrimaryPart
        end

        if not root or not root:IsA("BasePart") then
            return nil
        end

        return root.Position
    end)

    if not ok or not isFiniteVector3(position) then
        return nil
    end

    return position
end

local function validateDenseArray(source, maximum)
    if type(source) ~= "table" then
        return nil, "InvalidArray"
    end

    local count = 0

    for key in pairs(source) do
        if type(key) ~= "number"
            or key % 1 ~= 0
            or key < 1
            or key > maximum then
            return nil, "InvalidArrayIndex"
        end

        count += 1

        if count > maximum then
            return nil, "ArrayLimitExceeded"
        end
    end

    for index = 1, count do
        if rawget(source, index) == nil then
            return nil, "SparseArray"
        end
    end

    return count, "OK"
end

local function validateCandidate(candidate, now, maxAge)
    if type(candidate) ~= "table" then
        return false, "InvalidCandidate"
    end

    if type(candidate.id) ~= "string"
        or #candidate.id < 1
        or #candidate.id > 64 then
        return false, "InvalidCandidateId"
    end

    if not isFiniteVector3(candidate.position) then
        return false, "InvalidCandidatePosition"
    end

    if candidate.routeCandidateAvailable ~= true then
        return false, "NoRouteCandidate"
    end

    if candidate.routeIsHypothetical ~= true
        or candidate.requiresPhysicalValidation ~= true then
        return false, "InvalidRouteEvidence"
    end

    if candidate.feasibility ~= "WithinConfiguredEnvelope" then
        return false, "OutsideOrUnknownMovementEnvelope"
    end

    local uncertainty = candidate.uncertainty

    if uncertainty == nil then
        uncertainty = 1
    end

    if not isFiniteNumber(uncertainty)
        or uncertainty < 0
        or uncertainty > 1 then
        return false, "InvalidUncertainty"
    end

    local routeCost = candidate.routeCost

    if routeCost == nil then
        routeCost = 0
    end

    if not isFiniteNumber(routeCost) or routeCost < 0 then
        return false, "InvalidRouteCost"
    end

    if candidate.observedAt ~= nil then
        if not isFiniteNumber(candidate.observedAt) then
            return false, "InvalidObservationTimestamp"
        end

        local age = now - candidate.observedAt

        if age < 0 or age > maxAge then
            return false, "StaleCandidate"
        end
    end

    return true, {
        uncertainty = uncertainty,
        routeCost = routeCost,
    }
end

local function isBetterCandidate(left, right)
    if left.minimumClearance ~= right.minimumClearance then
        return left.minimumClearance > right.minimumClearance
    end

    if left.meanClearance ~= right.meanClearance then
        return left.meanClearance > right.meanClearance
    end

    if left.uncertainty ~= right.uncertainty then
        return left.uncertainty < right.uncertainty
    end

    if left.routeCost ~= right.routeCost then
        return left.routeCost < right.routeCost
    end

    return left.id < right.id
end

function EscapeDestinationEvaluator.new(config, dependencies, options)
    assert(type(config) == "table",
        "EscapeDestinationEvaluator requires config")

    assert(type(dependencies) == "table",
        "EscapeDestinationEvaluator requires dependencies")

    local characterManager = dependencies.characterManager

    assert(
        type(characterManager) == "table"
            and type(characterManager.GetRoot) == "function",
        "A compatible CharacterManager is required"
    )

    options = options or {}

    assert(type(options) == "table",
        "options must be a table")

    local maxCandidates = options.maxCandidates or 16
    local maxContacts = options.maxContacts or 16
    local maxCandidateAge = options.maxCandidateAge or 2.0
    local maxDecisionAge = options.maxDecisionAge or 0.75

    assert(
        isFiniteNumber(maxCandidates)
            and maxCandidates % 1 == 0
            and maxCandidates >= 1
            and maxCandidates <= 64,
        "maxCandidates must be an integer from 1 to 64"
    )

    assert(
        isFiniteNumber(maxContacts)
            and maxContacts % 1 == 0
            and maxContacts >= 1
            and maxContacts <= 32,
        "maxContacts must be an integer from 1 to 32"
    )

    assert(
        isFiniteNumber(maxCandidateAge)
            and maxCandidateAge > 0,
        "maxCandidateAge must be positive"
    )

    assert(
        isFiniteNumber(maxDecisionAge)
            and maxDecisionAge > 0,
        "maxDecisionAge must be positive"
    )

    return setmetatable({
        Config = config,
        CharacterManager = characterManager,

        _maxCandidates = maxCandidates,
        _maxContacts = maxContacts,
        _maxCandidateAge = maxCandidateAge,
        _maxDecisionAge = maxDecisionAge,

        _latest = nil,
        _destroyed = false,
    }, EscapeDestinationEvaluator)
end

function EscapeDestinationEvaluator:GetLatest()
    if self._destroyed then
        return nil, "Destroyed"
    end

    if not self._latest then
        return nil, "NoEvaluationAvailable"
    end

    return table.clone(self._latest), "OK"
end

function EscapeDestinationEvaluator:Evaluate(decision, candidates)
    if self._destroyed then
        return nil, "Destroyed"
    end

    if self.Config.enabled ~= true then
        return nil, "NavigationDisabled"
    end

    if type(decision) ~= "table"
        or decision.status ~= "ProposalReady"
        or decision.mode ~= "Escape"
        or decision.requiresRouteEvaluation ~= true then
        return nil, "InvalidEscapeDecision"
    end

    if decision.targetMode ~= self.Config.targetMode then
        return nil, "TargetModeMismatch"
    end

    local now = os.clock()

    if not isFiniteNumber(decision.timestamp) then
        return nil, "InvalidDecisionTimestamp"
    end

    local decisionAge = now - decision.timestamp

    if decisionAge < 0 or decisionAge > self._maxDecisionAge then
        return nil, "DecisionStale"
    end

    local candidateCount, candidateArrayReason =
        validateDenseArray(candidates, self._maxCandidates)

    if not candidateCount then
        return nil, candidateArrayReason
    end

    local contacts = decision.contacts

    local contactCount, contactArrayReason =
        validateDenseArray(contacts, self._maxContacts)

    if not contactCount then
        return nil, contactArrayReason
    end

    if contactCount == 0 then
        return nil, "NoObservedContacts"
    end

    local characterOk, character = pcall(function()
        return self.CharacterManager:GetCharacter()
    end)

    if not characterOk or not character then
        return nil, "LocalCharacterUnavailable"
    end

    local localRootOk, localRoot = pcall(function()
        return self.CharacterManager:GetRoot(character)
    end)

    if not localRootOk or not localRoot then
        return nil, "LocalRootUnavailable"
    end

    local localPositionOk, localPosition = pcall(function()
        return localRoot.Position
    end)

    if not localPositionOk or not isFiniteVector3(localPosition) then
        return nil, "LocalPositionUnavailable"
    end

    -- Require current positions for the entire observed contact set.
    -- Missing contact geometry must not silently improve a candidate's score.
    local contactPositions = table.create(contactCount)

    for index = 1, contactCount do
        local contact = contacts[index]

        if type(contact) ~= "table"
            or contact.kind ~= decision.targetMode
            or not isModel(contact.model) then
            return nil, "InvalidContactAtIndex" .. tostring(index)
        end

        local position = getRootPosition(contact.model)

        if not position then
            return nil, "ContactPositionUnavailableAtIndex"
                .. tostring(index)
        end

        contactPositions[index] = position
    end

    local evaluated = {}
    local rejectedCount = 0

    for index = 1, candidateCount do
        local candidate = candidates[index]

        local valid, metadata =
            validateCandidate(candidate, now, self._maxCandidateAge)

        if valid then
            local minimumClearance = math.huge
            local totalClearance = 0

            for contactIndex = 1, contactCount do
                local clearance =
                    (candidate.position - contactPositions[contactIndex]).Magnitude

                if not isFiniteNumber(clearance) then
                    return nil, "InvalidClearanceCalculation"
                end

                minimumClearance = math.min(
                    minimumClearance,
                    clearance
                )

                totalClearance += clearance
            end

            local meanClearance = totalClearance / contactCount

            local localDistance =
                (candidate.position - localPosition).Magnitude

            if not isFiniteNumber(localDistance) then
                rejectedCount += 1
                continue
            end

            evaluated[#evaluated + 1] = {
                id = candidate.id,
                position = candidate.position,

                minimumClearance = minimumClearance,
                meanClearance = meanClearance,

                uncertainty = metadata.uncertainty,
                routeCost = metadata.routeCost,

                localDistance = localDistance,
            }
        else
            rejectedCount += 1
        end
    end

    if #evaluated == 0 then
        return nil, "NoUsableDestinationCandidates"
    end

    table.sort(evaluated, isBetterCandidate)

    local selected = evaluated[1]

    local result = {
        status = decision.partialAnalysis
            and "ProvisionalDestination"
            or "DestinationEvaluated",

        mode = "Escape",
        reason = "BestCandidateByMultiContactClearance",

        destination = selected.position,
        candidateId = selected.id,

        minimumContactClearance = selected.minimumClearance,
        meanContactClearance = selected.meanClearance,

        uncertainty = selected.uncertainty,
        routeCost = selected.routeCost,
        localDistance = selected.localDistance,

        contactsConsidered = contactCount,
        candidatesConsidered = candidateCount,
        candidatesAccepted = #evaluated,
        candidatesRejected = rejectedCount,

        partialAnalysis = decision.partialAnalysis == true,

        evaluatedAt = now,

        limitations = {
            "Clearance is based on current observed contact positions.",
            "Predicted threat trajectories are not evaluated here.",
            "Unobserved contacts and geometry may change the result.",
            "Reachability and movement feasibility are supplied inputs.",
            "A selected destination is not a guarantee of safety.",
        },
    }

    self._latest = result

    return table.clone(result), "OK"
end

function EscapeDestinationEvaluator:Reset()
    if self._destroyed then
        return false, "Destroyed"
    end

    self._latest = nil

    return true, "Reset"
end

function EscapeDestinationEvaluator:Destroy()
    if self._destroyed then
        return
    end

    self._latest = nil
    self.Config = nil
    self.CharacterManager = nil
    self._destroyed = true
end

return EscapeDestinationEvaluator

-- Navigation Architecture v2.2
-- Behavior module: EscapeDestinationEvaluator
--
-- Responsibilities:
--   - Evaluate caller-supplied arena destination candidates.
--   - Compare each candidate against every observed contact.
--   - Require supplied reachability and movement-feasibility approval.
--   - Prefer destinations with better minimum separation.
--   - Account for route cost and observation uncertainty.
--   - Preserve partial-analysis limitations in the result.
--
-- This module does NOT:
--   - Scan the world or generate arena geometry.
--   - Assume that unobserved space is safe.
--   - Infer hostile intent.
--   - Guarantee collision-free movement.
--   - Execute movement or request paths.
--
-- Candidate input contract:
-- {
--     id = "Surface_01",
--     position = Vector3,
--     reachable = true,
--     feasibility = "WithinConfiguredEnvelope",
--     uncertainty = 0.0,       -- optional, 0 to 1
--     routeCost = 10.0,        -- optional, non-negative
--     observedAt = os.clock(), -- optional, timestamp
-- }
--
-- Candidates must be normalized by an adapter using actual
-- Arena Analysis outputs. This module does not assume undocumented
-- L1-L5 result fields.

local EscapeDestinationEvaluator = {}
EscapeDestinationEvaluator.__index = EscapeDestinationEvaluator

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

local function getRootPosition(model)
    if not isModel(model) then
        return nil
    end

    local ok, position = pcall(function()
        local root = model:FindFirstChild("HumanoidRootPart")

        if not root or not root:IsA("BasePart") then
            root = model.PrimaryPart
        end

        if not root or not root:IsA("BasePart") then
            return nil
        end

        return root.Position
    end)

    if not ok or not isFiniteVector3(position) then
        return nil
    end

    return position
end

local function validateDenseArray(source, maximum)
    if type(source) ~= "table" then
        return nil, "InvalidArray"
    end

    local count = 0

    for key in pairs(source) do
        if type(key) ~= "number"
            or key % 1 ~= 0
            or key < 1
            or key > maximum then
            return nil, "InvalidArrayIndex"
        end

        count += 1

        if count > maximum then
            return nil, "ArrayLimitExceeded"
        end
    end

    for index = 1, count do
        if rawget(source, index) == nil then
            return nil, "SparseArray"
        end
    end

    return count, "OK"
end

local function validateCandidate(candidate, now, maxAge)
    if type(candidate) ~= "table" then
        return false, "InvalidCandidate"
    end

    if type(candidate.id) ~= "string"
        or #candidate.id < 1
        or #candidate.id > 64 then
        return false, "InvalidCandidateId"
    end

    if not isFiniteVector3(candidate.position) then
        return false, "InvalidCandidatePosition"
    end

    if candidate.reachable ~= true then
        return false, "NotReachable"
    end

    if candidate.feasibility ~= "WithinConfiguredEnvelope" then
        return false, "OutsideOrUnknownMovementEnvelope"
    end

    local uncertainty = candidate.uncertainty

    if uncertainty == nil then
        uncertainty = 1
    end

    if not isFiniteNumber(uncertainty)
        or uncertainty < 0
        or uncertainty > 1 then
        return false, "InvalidUncertainty"
    end

    local routeCost = candidate.routeCost

    if routeCost == nil then
        routeCost = 0
    end

    if not isFiniteNumber(routeCost) or routeCost < 0 then
        return false, "InvalidRouteCost"
    end

    if candidate.observedAt ~= nil then
        if not isFiniteNumber(candidate.observedAt) then
            return false, "InvalidObservationTimestamp"
        end

        local age = now - candidate.observedAt

        if age < 0 or age > maxAge then
            return false, "StaleCandidate"
        end
    end

    return true, {
        uncertainty = uncertainty,
        routeCost = routeCost,
    }
end

local function isBetterCandidate(left, right)
    if left.minimumClearance ~= right.minimumClearance then
        return left.minimumClearance > right.minimumClearance
    end

    if left.meanClearance ~= right.meanClearance then
        return left.meanClearance > right.meanClearance
    end

    if left.uncertainty ~= right.uncertainty then
        return left.uncertainty < right.uncertainty
    end

    if left.routeCost ~= right.routeCost then
        return left.routeCost < right.routeCost
    end

    return left.id < right.id
end

function EscapeDestinationEvaluator.new(config, dependencies, options)
    assert(type(config) == "table",
        "EscapeDestinationEvaluator requires config")

    assert(type(dependencies) == "table",
        "EscapeDestinationEvaluator requires dependencies")

    local characterManager = dependencies.characterManager

    assert(
        type(characterManager) == "table"
            and type(characterManager.GetRoot) == "function",
        "A compatible CharacterManager is required"
    )

    options = options or {}

    assert(type(options) == "table",
        "options must be a table")

    local maxCandidates = options.maxCandidates or 16
    local maxContacts = options.maxContacts or 16
    local maxCandidateAge = options.maxCandidateAge or 2.0
    local maxDecisionAge = options.maxDecisionAge or 0.75

    assert(
        isFiniteNumber(maxCandidates)
            and maxCandidates % 1 == 0
            and maxCandidates >= 1
            and maxCandidates <= 64,
        "maxCandidates must be an integer from 1 to 64"
    )

    assert(
        isFiniteNumber(maxContacts)
            and maxContacts % 1 == 0
            and maxContacts >= 1
            and maxContacts <= 32,
        "maxContacts must be an integer from 1 to 32"
    )

    assert(
        isFiniteNumber(maxCandidateAge)
            and maxCandidateAge > 0,
        "maxCandidateAge must be positive"
    )

    assert(
        isFiniteNumber(maxDecisionAge)
            and maxDecisionAge > 0,
        "maxDecisionAge must be positive"
    )

    return setmetatable({
        Config = config,
        CharacterManager = characterManager,

        _maxCandidates = maxCandidates,
        _maxContacts = maxContacts,
        _maxCandidateAge = maxCandidateAge,
        _maxDecisionAge = maxDecisionAge,

        _latest = nil,
        _destroyed = false,
    }, EscapeDestinationEvaluator)
end

function EscapeDestinationEvaluator:GetLatest()
    if self._destroyed then
        return nil, "Destroyed"
    end

    if not self._latest then
        return nil, "NoEvaluationAvailable"
    end

    return table.clone(self._latest), "OK"
end

function EscapeDestinationEvaluator:Evaluate(decision, candidates)
    if self._destroyed then
        return nil, "Destroyed"
    end

    if self.Config.enabled ~= true then
        return nil, "NavigationDisabled"
    end

    if type(decision) ~= "table"
        or decision.status ~= "ProposalReady"
        or decision.mode ~= "Escape"
        or decision.requiresRouteEvaluation ~= true then
        return nil, "InvalidEscapeDecision"
    end

    if decision.targetMode ~= self.Config.targetMode then
        return nil, "TargetModeMismatch"
    end

    local now = os.clock()

    if not isFiniteNumber(decision.timestamp) then
        return nil, "InvalidDecisionTimestamp"
    end

    local decisionAge = now - decision.timestamp

    if decisionAge < 0 or decisionAge > self._maxDecisionAge then
        return nil, "DecisionStale"
    end

    local candidateCount, candidateArrayReason =
        validateDenseArray(candidates, self._maxCandidates)

    if not candidateCount then
        return nil, candidateArrayReason
    end

    local contacts = decision.contacts

    local contactCount, contactArrayReason =
        validateDenseArray(contacts, self._maxContacts)

    if not contactCount then
        return nil, contactArrayReason
    end

    if contactCount == 0 then
        return nil, "NoObservedContacts"
    end

    local characterOk, character = pcall(function()
        return self.CharacterManager:GetCharacter()
    end)

    if not characterOk or not character then
        return nil, "LocalCharacterUnavailable"
    end

    local localRootOk, localRoot = pcall(function()
        return self.CharacterManager:GetRoot(character)
    end)

    if not localRootOk or not localRoot then
        return nil, "LocalRootUnavailable"
    end

    local localPositionOk, localPosition = pcall(function()
        return localRoot.Position
    end)

    if not localPositionOk or not isFiniteVector3(localPosition) then
        return nil, "LocalPositionUnavailable"
    end

    -- Require current positions for the entire observed contact set.
    -- Missing contact geometry must not silently improve a candidate's score.
    local contactPositions = table.create(contactCount)

    for index = 1, contactCount do
        local contact = contacts[index]

        if type(contact) ~= "table"
            or contact.kind ~= decision.targetMode
            or not isModel(contact.model) then
            return nil, "InvalidContactAtIndex" .. tostring(index)
        end

        local position = getRootPosition(contact.model)

        if not position then
            return nil, "ContactPositionUnavailableAtIndex"
                .. tostring(index)
        end

        contactPositions[index] = position
    end

    local evaluated = {}
    local rejectedCount = 0

    for index = 1, candidateCount do
        local candidate = candidates[index]

        local valid, metadata =
            validateCandidate(candidate, now, self._maxCandidateAge)

        if valid then
            local minimumClearance = math.huge
            local totalClearance = 0

            for contactIndex = 1, contactCount do
                local clearance =
                    (candidate.position - contactPositions[contactIndex]).Magnitude

                if not isFiniteNumber(clearance) then
                    return nil, "InvalidClearanceCalculation"
                end

                minimumClearance = math.min(
                    minimumClearance,
                    clearance
                )

                totalClearance += clearance
            end

            local meanClearance = totalClearance / contactCount

            local localDistance =
                (candidate.position - localPosition).Magnitude

            if not isFiniteNumber(localDistance) then
                rejectedCount += 1
                continue
            end

            evaluated[#evaluated + 1] = {
                id = candidate.id,
                position = candidate.position,

                minimumClearance = minimumClearance,
                meanClearance = meanClearance,

                uncertainty = metadata.uncertainty,
                routeCost = metadata.routeCost,

                localDistance = localDistance,
            }
        else
            rejectedCount += 1
        end
    end

    if #evaluated == 0 then
        return nil, "NoUsableDestinationCandidates"
    end

    table.sort(evaluated, isBetterCandidate)

    local selected = evaluated[1]

    local result = {
        status = decision.partialAnalysis
            and "ProvisionalDestination"
            or "DestinationEvaluated",

        mode = "Escape",
        reason = "BestCandidateByMultiContactClearance",

        destination = selected.position,
        candidateId = selected.id,

        minimumContactClearance = selected.minimumClearance,
        meanContactClearance = selected.meanClearance,

        uncertainty = selected.uncertainty,
        routeCost = selected.routeCost,
        localDistance = selected.localDistance,

        contactsConsidered = contactCount,
        candidatesConsidered = candidateCount,
        candidatesAccepted = #evaluated,
        candidatesRejected = rejectedCount,

        partialAnalysis = decision.partialAnalysis == true,

        evaluatedAt = now,

        limitations = {
            "Clearance is based on current observed contact positions.",
            "Predicted threat trajectories are not evaluated here.",
            "Unobserved contacts and geometry may change the result.",
            "Reachability and movement feasibility are supplied inputs.",
            "A selected destination is not a guarantee of safety.",
        },
    }

    self._latest = result

    return table.clone(result), "OK"
end

function EscapeDestinationEvaluator:Reset()
    if self._destroyed then
        return false, "Destroyed"
    end

    self._latest = nil

    return true, "Reset"
end

function EscapeDestinationEvaluator:Destroy()
    if self._destroyed then
        return
    end

    self._latest = nil
    self.Config = nil
    self.CharacterManager = nil
    self._destroyed = true
end

return EscapeDestinationEvaluator
