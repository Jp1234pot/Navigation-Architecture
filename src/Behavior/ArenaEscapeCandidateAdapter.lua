
-- Navigation Architecture v2.2
-- Behavior adapter: ArenaEscapeCandidateAdapter
--
-- Converts one explicit L1-L5 arena analysis into the candidate contract
-- consumed by EscapeDestinationEvaluator.
--
-- This adapter does not select threats, schedule scans, execute movement,
-- or guarantee physical reachability or safety. All dependencies are
-- injected and remain caller-owned.

local ArenaEscapeCandidateAdapter = {}
ArenaEscapeCandidateAdapter.__index = ArenaEscapeCandidateAdapter

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

local function hasMethods(value, methods)
    if type(value) ~= "table" then
        return false
    end

    for _, methodName in ipairs(methods) do
        if type(value[methodName]) ~= "function" then
            return false
        end
    end

    return true
end

local function hasCenterSource(surface)
    if type(surface) ~= "table" or type(surface.sources) ~= "table" then
        return false
    end

    for _, source in ipairs(surface.sources) do
        if source == "Center" then
            return true
        end
    end

    return false
end

local function buildUncertaintyMap(confidence)
    local result = {}

    if type(confidence) ~= "table"
        or confidence.status ~= "Integrated"
        or type(confidence.surfaceResults) ~= "table" then
        return result
    end

    for _, item in ipairs(confidence.surfaceResults) do
        if type(item) == "table"
            and type(item.surfaceId) == "string"
            and isFiniteNumber(item.uncertainty)
            and item.uncertainty >= 0
            and item.uncertainty <= 1 then
            result[item.surfaceId] = item.uncertainty
        end
    end

    return result
end

local function selectPassingRoute(comparisonPacket)
    if type(comparisonPacket) ~= "table"
        or type(comparisonPacket.comparison) ~= "table"
        or type(comparisonPacket.comparison.routes) ~= "table"
        or type(comparisonPacket.feasibility) ~= "table" then
        return nil
    end

    local routes = comparisonPacket.comparison.routes
    local bestRoute = nil

    for _, item in ipairs(comparisonPacket.feasibility) do
        if type(item) == "table"
            and isFiniteNumber(item.routeIndex)
            and item.routeIndex % 1 == 0
            and item.routeIndex >= 1 then

            local route = routes[item.routeIndex]
            local assessment = item.assessment

            if type(route) == "table"
                and type(assessment) == "table"
                and assessment.status == "WithinConfiguredEnvelope"
                and assessment.isGuaranteedReachable == false
                and assessment.requiresPhysicalValidation == true
                and isFiniteNumber(route.totalCost)
                and route.totalCost >= 0 then

                if not bestRoute or route.totalCost < bestRoute.totalCost then
                    bestRoute = route
                end
            end
        end
    end

    return bestRoute
end

function ArenaEscapeCandidateAdapter.new(dependencies, options)
    assert(type(dependencies) == "table",
        "ArenaEscapeCandidateAdapter requires dependencies")

    assert(
        hasMethods(dependencies.arenaAnalysisPipeline, {
            "Observe",
            "Compare",
            "GetLatest",
        }),
        "A compatible ArenaAnalysisPipeline is required"
    )

    assert(
        hasMethods(dependencies.characterManager, {
            "GetCharacter",
            "GetRoot",
        }),
        "A compatible CharacterManager is required"
    )

    options = options or {}
    assert(type(options) == "table",
        "ArenaEscapeCandidateAdapter options must be a table")

    local maxCandidates = options.maxCandidates or 16

    assert(isFiniteNumber(maxCandidates)
        and maxCandidates % 1 == 0
        and maxCandidates >= 1
        and maxCandidates <= 16,
        "maxCandidates must be an integer from 1 to 16")

    return setmetatable({
        ArenaAnalysisPipeline = dependencies.arenaAnalysisPipeline,
        CharacterManager = dependencies.characterManager,
        _maxCandidates = maxCandidates,
        _latest = nil,
        _destroyed = false,
    }, ArenaEscapeCandidateAdapter)
end

-- Explicitly observes local geometry and builds destinations that:
--   1. Have a directed L4 candidate route from the Center surface.
--   2. Have at least one route passing the supplied L5 envelope.
--
-- The movement envelope must come from the caller.
function ArenaEscapeCandidateAdapter:BuildCandidates(movementEnvelope, stores)
    if self._destroyed then
        return nil, "Destroyed"
    end

    if type(movementEnvelope) ~= "table" then
        return nil, "MovementEnvelopeRequired"
    end

    local characterOk, character = pcall(function()
        return self.CharacterManager:GetCharacter()
    end)

    if not characterOk or not character then
        return nil, "LocalCharacterUnavailable"
    end

    local rootOk, root = pcall(function()
        return self.CharacterManager:GetRoot(character)
    end)

    if not rootOk or not root then
        return nil, "LocalRootUnavailable"
    end

    local positionOk, origin = pcall(function()
        return root.Position
    end)

    if not positionOk or not isFiniteVector3(origin) then
        return nil, "LocalPositionUnavailable"
    end

    local observeOk, observation, observationStatus = pcall(function()
        return self.ArenaAnalysisPipeline:Observe(
            origin,
            character,
            stores
        )
    end)

    if not observeOk then
        return nil, "ArenaObservationError:" .. tostring(observation)
    end

    if type(observation) ~= "table"
        or type(observation.report) ~= "table"
        or type(observation.report.surfaces) ~= "table" then
        return nil, observationStatus or "ArenaObservationUnavailable"
    end

    local report = observation.report
    local startSurface = nil

    for _, surface in ipairs(report.surfaces) do
        if hasCenterSource(surface) then
            startSurface = surface
            break
        end
    end

    if not startSurface
        or type(startSurface.id) ~= "string"
        or not isFiniteVector3(startSurface.position) then
        self._latest = nil
        return nil, "LocalCenterSurfaceUnavailable"
    end

    local uncertaintyBySurface =
        buildUncertaintyMap(observation.confidence)

    local candidates = {}
    local comparisons = 0
    local routesFound = 0
    local feasibilityAccepted = 0
    local rejected = 0

    for _, surface in ipairs(report.surfaces) do
        if #candidates >= self._maxCandidates then
            break
        end

        if type(surface) == "table"
            and type(surface.id) == "string"
            and surface.id ~= startSurface.id
            and isFiniteVector3(surface.position) then

            comparisons += 1

            local compareOk, comparisonPacket = pcall(function()
                return self.ArenaAnalysisPipeline:Compare(
                    startSurface.id,
                    surface.id,
                    movementEnvelope,
                    stores
                )
            end)

            if compareOk
                and type(comparisonPacket) == "table"
                and type(comparisonPacket.comparison) == "table"
                and comparisonPacket.comparison.routeCount > 0 then

                routesFound += 1

                local route = selectPassingRoute(comparisonPacket)

                if route then
                    feasibilityAccepted += 1

                    candidates[#candidates + 1] = {
                        id = surface.id,
                        position = surface.position,
                        reachable = true,
                        feasibility = "WithinConfiguredEnvelope",
                        uncertainty = uncertaintyBySurface[surface.id] or 1,
                        routeCost = route.totalCost,
                        observedAt = report.timestamp,

                        routeIsHypothetical = true,
                        requiresPhysicalValidation = true,
                    }
                else
                    rejected += 1
                end
            else
                rejected += 1
            end
        end
    end

    local result = {
        status = #candidates > 0
            and "CandidatesBuilt"
            or "NoFeasibleSurfaceCandidates",

        candidates = candidates,
        startSurfaceId = startSurface.id,
        observedAt = report.timestamp,
        confidenceStatus = observation.confidenceStatus,

        comparisons = comparisons,
        routesFound = routesFound,
        feasibilityAccepted = feasibilityAccepted,
        rejected = rejected,

        limits = {
            candidateSetIsLocalObservation = true,
            routeSearchIsExhaustive = false,
            movementFeasibilityIsHeuristic = true,
            physicalReachabilityGuaranteed = false,
            safetyGuaranteed = false,
            movementExecuted = false,
        },
    }

    self._latest = result

    return table.clone(candidates), result.status, table.clone(result)
end

function ArenaEscapeCandidateAdapter:GetLatest()
    if self._destroyed then
        return nil, "Destroyed"
    end

    if not self._latest then
        return nil, "NoCandidateBuildAvailable"
    end

    return table.clone(self._latest), "OK"
end

function ArenaEscapeCandidateAdapter:Reset()
    if self._destroyed then
        return false, "Destroyed"
    end

    self._latest = nil
    return true, "Reset"
end

function ArenaEscapeCandidateAdapter:Destroy()
    if self._destroyed then
        return
    end

    -- Injected dependencies remain caller-owned.
    self._latest = nil
    self.ArenaAnalysisPipeline = nil
    self.CharacterManager = nil
    self._destroyed = true
end

return ArenaEscapeCandidateAdapter
