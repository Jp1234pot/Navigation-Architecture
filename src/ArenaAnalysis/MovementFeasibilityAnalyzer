-- Navigation Architecture v2.2
-- Foundation L5: MovementFeasibilityAnalyzer
-- Read-only envelope checks for caller-supplied hypothetical L4 routes.
-- No character inspection, world queries, physics simulation, or movement.

local MovementFeasibilityAnalyzer = {}
MovementFeasibilityAnalyzer.__index = MovementFeasibilityAnalyzer

local ALLOWED_RELATIONS = {
    WalkCandidate = true,
    JumpCandidate = true,
    DropCandidate = true,
}

local function isFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function validateEnvelope(envelope)
    assert(type(envelope) == "table", "movementEnvelope must be a table")

    local result = {
        maxWalkGap = envelope.maxWalkGap,
        maxStepUp = envelope.maxStepUp,
        maxDropHeight = envelope.maxDropHeight,
        maxJumpHorizontalDistance = envelope.maxJumpHorizontalDistance,
        maxDropHorizontalDistance = envelope.maxDropHorizontalDistance,
        maxJumpRise = envelope.maxJumpRise,
        maxJumpDrop = envelope.maxJumpDrop,
    }

    local bounds = {
        maxWalkGap = { 0, 48 },
        maxStepUp = { 0, 16 },
        maxDropHeight = { 0, 64 },
        maxJumpHorizontalDistance = { 0, 64 },
        maxDropHorizontalDistance = { 0, 64 },
        maxJumpRise = { 0, 32 },
        maxJumpDrop = { 0, 64 },
    }

    for key, range in pairs(bounds) do
        local value = result[key]
        assert(isFiniteNumber(value) and value >= range[1] and value <= range[2],
            key .. " must be a finite number from " .. range[1] .. " to " .. range[2])
    end

    return result
end

local function validateRoute(route, maxLegs)
    if type(route) ~= "table" or route.isHypothetical ~= true
        or route.isGuaranteedReachable ~= false or route.requiresValidation ~= true
        or type(route.legs) ~= "table" or not isFiniteNumber(route.legCount)
        or route.legCount % 1 ~= 0 or route.legCount ~= #route.legs then
        return false, "InvalidRoute"
    end
    if route.legCount < 1 or route.legCount > maxLegs then
        return false, "LegLimitExceeded"
    end

    for index, leg in ipairs(route.legs) do
        if index > maxLegs or type(leg) ~= "table"
            or type(leg.from) ~= "string" or #leg.from < 1 or #leg.from > 32
            or type(leg.to) ~= "string" or #leg.to < 1 or #leg.to > 32
            or leg.from == leg.to or not ALLOWED_RELATIONS[leg.relation]
            or not isFiniteNumber(leg.horizontalGap) or leg.horizontalGap < 0
            or not isFiniteNumber(leg.verticalDelta)
            or leg.requiresValidation ~= true then
            return false, "InvalidRouteLeg"
        end
    end

    return true
end

local function assessLeg(leg, envelope)
    local horizontal = leg.horizontalGap
    local vertical = leg.verticalDelta
    if leg.relation == "WalkCandidate" then
        if horizontal <= envelope.maxWalkGap and vertical <= envelope.maxStepUp
            and vertical >= -envelope.maxDropHeight then
            return "WithinConfiguredEnvelope", "Within supplied walk and step limits"
        end
        return "OutsideConfiguredEnvelope", "Exceeds supplied walk gap, step-up, or drop limit"
    end

    if leg.relation == "JumpCandidate" then
        if horizontal > envelope.maxJumpHorizontalDistance then
            return "OutsideConfiguredEnvelope", "Exceeds supplied jump horizontal limit"
        end
        if vertical > envelope.maxJumpRise then
            return "OutsideConfiguredEnvelope", "Exceeds supplied jump-rise limit"
        end
        if vertical < -envelope.maxJumpDrop then
            return "OutsideConfiguredEnvelope", "Exceeds supplied jump-drop limit"
        end
        return "WithinConfiguredEnvelope", "Within supplied jump envelope; trajectory and landing remain unverified"
    end

    if vertical < 0 and horizontal <= envelope.maxDropHorizontalDistance
        and -vertical <= envelope.maxDropHeight then
        return "WithinConfiguredEnvelope", "Within supplied drop and horizontal limits"
    end
    return "OutsideConfiguredEnvelope", "Drop direction, height, or horizontal distance exceeds supplied limits"
end

function MovementFeasibilityAnalyzer.new(options)
    options = options or {}
    assert(type(options) == "table", "options must be a table")
    local maxLegs = options.maxLegs or 16
    assert(isFiniteNumber(maxLegs) and maxLegs % 1 == 0
        and maxLegs >= 1 and maxLegs <= 16, "maxLegs must be an integer from 1 to 16")

    return setmetatable({
        _maxLegs = maxLegs,
        _destroyed = false,
        _analysisCount = 0,
    }, MovementFeasibilityAnalyzer)
end

-- Analyze one L4 route against explicit caller-supplied movement limits.
-- The envelope must be based on authorized test-character settings or
-- conservative test assumptions. This module does not read the character.
function MovementFeasibilityAnalyzer:Analyze(route, movementEnvelope)
    if self._destroyed then
        return nil, "Destroyed"
    end

    local valid, reason = validateRoute(route, self._maxLegs)
    if not valid then
        return nil, reason
    end

    local envelope = validateEnvelope(movementEnvelope)
    local legResults = {}
    local withinCount = 0
    local outsideCount = 0

    for index, leg in ipairs(route.legs) do
        local status, explanation = assessLeg(leg, envelope)
        if status == "WithinConfiguredEnvelope" then
            withinCount += 1
        else
            outsideCount += 1
        end

        legResults[#legResults + 1] = {
            index = index,
            from = leg.from,
            to = leg.to,
            relation = leg.relation,
            status = status,
            reason = explanation,
            requiresPhysicalValidation = true,
        }
    end

    local overallStatus = outsideCount > 0
        and "OutsideConfiguredEnvelope"
        or "WithinConfiguredEnvelope"

    self._analysisCount += 1
    return {
        status = overallStatus,
        legCount = route.legCount,
        withinEnvelopeCount = withinCount,
        outsideEnvelopeCount = outsideCount,
        legs = legResults,
        sourceRouteCost = route.totalCost,
        isHeuristicAssessment = true,
        isPhysicalSimulation = false,
        isGuaranteedReachable = false,
        requiresPhysicalValidation = true,
        movementExecuted = false,
        envelope = envelope,
    }, "Analyzed"
end

function MovementFeasibilityAnalyzer:GetAnalysisCount()
    return self._analysisCount
end

function MovementFeasibilityAnalyzer:Destroy()
    self._destroyed = true
end

return MovementFeasibilityAnalyzer
