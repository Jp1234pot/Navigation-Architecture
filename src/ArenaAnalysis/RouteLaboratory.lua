-- Navigation Architecture v2.2
-- Foundation L4: RouteLaboratory
-- Bounded, hypothetical route comparison over caller-supplied L2/L3 reports.
-- No world access, raycasts, scheduling, movement, or automatic route execution.

local RouteLaboratory = {}
RouteLaboratory.__index = RouteLaboratory

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

local function isFiniteVector3(value)
    return typeof(value) == "Vector3"
        and isFiniteNumber(value.X)
        and isFiniteNumber(value.Y)
        and isFiniteNumber(value.Z)
end

local function validateOptions(options)
    options = options or {}
    assert(type(options) == "table", "options must be a table")

    local result = {
        maxReportAge = options.maxReportAge or 5,
        maxSurfaces = options.maxSurfaces or 17,
        maxConnections = options.maxConnections or 136,
        maxRoutes = options.maxRoutes or 3,
        verticalWeight = options.verticalWeight or 1.25,
        uncertaintyPenalty = options.uncertaintyPenalty or 8,
        walkPenalty = options.walkPenalty or 0,
        jumpPenalty = options.jumpPenalty or 2,
        dropPenalty = options.dropPenalty or 1.5,
        defaultUncertainty = options.defaultUncertainty or 0.5,
        recordDecision = options.recordDecision == true,
    }

    assert(isFiniteNumber(result.maxReportAge) and result.maxReportAge >= 0.25
        and result.maxReportAge <= 30, "maxReportAge must be from 0.25 to 30 seconds")
    assert(isFiniteNumber(result.maxSurfaces) and result.maxSurfaces % 1 == 0
        and result.maxSurfaces >= 1 and result.maxSurfaces <= 17,
        "maxSurfaces must be an integer from 1 to 17")
    assert(isFiniteNumber(result.maxConnections) and result.maxConnections % 1 == 0
        and result.maxConnections >= 0 and result.maxConnections <= 136,
        "maxConnections must be an integer from 0 to 136")
    assert(isFiniteNumber(result.maxRoutes) and result.maxRoutes % 1 == 0
        and result.maxRoutes >= 1 and result.maxRoutes <= 4,
        "maxRoutes must be an integer from 1 to 4")
    for _, key in ipairs({ "verticalWeight", "uncertaintyPenalty", "walkPenalty", "jumpPenalty", "dropPenalty" }) do
        assert(isFiniteNumber(result[key]) and result[key] >= 0 and result[key] <= 100,
            key .. " must be from 0 to 100")
    end
    assert(isFiniteNumber(result.defaultUncertainty) and result.defaultUncertainty >= 0
        and result.defaultUncertainty <= 1, "defaultUncertainty must be from 0 to 1")
    assert(type(result.recordDecision) == "boolean", "recordDecision must be boolean")

    return result
end

local function edgeKey(fromId, toId)
    return fromId .. "\0" .. toId
end

local function relationPenalty(relation, options)
    if relation == "WalkCandidate" then
        return options.walkPenalty
    elseif relation == "JumpCandidate" then
        return options.jumpPenalty
    end
    return options.dropPenalty
end

local function validateInputs(report, startId, goalId, confidence, options, now)
    if type(report) ~= "table" or not isFiniteNumber(report.timestamp)
        or type(report.surfaces) ~= "table" or type(report.connections) ~= "table"
        or not isFiniteNumber(report.surfaceCount) or not isFiniteNumber(report.connectionCount)
        or report.surfaceCount % 1 ~= 0 or report.connectionCount % 1 ~= 0
        or report.surfaceCount ~= #report.surfaces or report.connectionCount ~= #report.connections then
        return false, "InvalidReport"
    end
    if report.surfaceCount > options.maxSurfaces then
        return false, "SurfaceLimitExceeded"
    end
    if report.connectionCount > options.maxConnections then
        return false, "ConnectionLimitExceeded"
    end
    local age = now - report.timestamp
    if not isFiniteNumber(age) or age < 0 then
        return false, "InvalidTimestamp"
    end
    if age > options.maxReportAge then
        return false, "StaleReport"
    end

    local surfaceById = {}
    for index, surface in ipairs(report.surfaces) do
        if index > options.maxSurfaces or type(surface) ~= "table"
            or type(surface.id) ~= "string" or #surface.id < 1 or #surface.id > 32
            or not isFiniteVector3(surface.position) then
            return false, "InvalidSurfaceRecord"
        end
        if surfaceById[surface.id] then
            return false, "DuplicateSurfaceId"
        end
        surfaceById[surface.id] = surface
    end
    if not surfaceById[startId] or not surfaceById[goalId] then
        return false, "UnknownEndpoint"
    end
    if startId == goalId then
        return false, "SameEndpoint"
    end

    for index, connection in ipairs(report.connections) do
        if index > options.maxConnections or type(connection) ~= "table"
            or not surfaceById[connection.from] or not surfaceById[connection.to]
            or connection.from == connection.to or not ALLOWED_RELATIONS[connection.relation]
            or not isFiniteNumber(connection.horizontalGap) or connection.horizontalGap < 0
            or not isFiniteNumber(connection.verticalDelta)
            or connection.requiresValidation ~= true or connection.isGuaranteedReachable ~= false then
            return false, "InvalidConnectionRecord"
        end
    end

    local uncertaintyById = {}
    local confidenceSource = "DefaultEstimate"
    if confidence ~= nil then
        if type(confidence) ~= "table" or confidence.status ~= "Integrated"
            or confidence.sourceTimestamp ~= report.timestamp
            or not isFiniteNumber(confidence.overallUncertainty)
            or confidence.overallUncertainty < 0 or confidence.overallUncertainty > 1
            or type(confidence.surfaceResults) ~= "table"
            or #confidence.surfaceResults ~= report.surfaceCount then
            return false, "InvalidSpatialConfidence"
        end
        if not isFiniteNumber(confidence.timestamp) then
            return false, "InvalidSpatialConfidence"
        end
        local confidenceAge = now - confidence.timestamp
        if confidenceAge < 0 or confidenceAge > options.maxReportAge then
            return false, "StaleSpatialConfidence"
        end
        for _, item in ipairs(confidence.surfaceResults) do
            if type(item) ~= "table" or type(item.surfaceId) ~= "string"
                or not surfaceById[item.surfaceId] or not isFiniteNumber(item.uncertainty)
                or item.uncertainty < 0 or item.uncertainty > 1
                or uncertaintyById[item.surfaceId] ~= nil then
                return false, "InvalidSurfaceConfidence"
            end
            uncertaintyById[item.surfaceId] = item.uncertainty
        end
        for id in pairs(surfaceById) do
            if uncertaintyById[id] == nil then
                return false, "IncompleteSurfaceConfidence"
            end
        end
        confidenceSource = "FoundationL3"
    else
        for id in pairs(surfaceById) do
            uncertaintyById[id] = options.defaultUncertainty
        end
    end

    return true, {
        age = age,
        surfaces = surfaceById,
        uncertainty = uncertaintyById,
        confidenceSource = confidenceSource,
    }
end

local function edgeCost(connection, uncertaintyById, options)
    local endpointUncertainty = (uncertaintyById[connection.from]
        + uncertaintyById[connection.to]) * 0.5
    local verticalMagnitude = math.abs(connection.verticalDelta)
    return connection.horizontalGap
        + verticalMagnitude * options.verticalWeight
        + relationPenalty(connection.relation, options)
        + endpointUncertainty * options.uncertaintyPenalty
end

-- Dijkstra with a bounded node set. `blockedEdge` is used only to derive
-- alternative hypothetical routes after the primary route is found.
local function shortestPath(surfaceById, connections, uncertaintyById, options, startId, goalId, blockedEdge)
    local adjacency = {}
    for id in pairs(surfaceById) do
        adjacency[id] = {}
    end
    for _, connection in ipairs(connections) do
        local key = edgeKey(connection.from, connection.to)
        if key ~= blockedEdge then
            adjacency[connection.from][#adjacency[connection.from] + 1] = {
                to = connection.to,
                source = connection,
                cost = edgeCost(connection, uncertaintyById, options),
            }
        end
    end

    local distances = { [startId] = 0 }
    local previous = {}
    local visited = {}

    for _ = 1, #connections + #surfaceById do
        local currentId = nil
        local currentDistance = math.huge
        for id, distance in pairs(distances) do
            if not visited[id] and distance < currentDistance then
                currentId = id
                currentDistance = distance
            end
        end
        if currentId == nil then
            break
        end
        if currentId == goalId then
            break
        end
        visited[currentId] = true
        for _, edge in ipairs(adjacency[currentId]) do
            if not visited[edge.to] then
                local nextDistance = currentDistance + edge.cost
                local oldDistance = distances[edge.to]
                if oldDistance == nil or nextDistance < oldDistance then
                    distances[edge.to] = nextDistance
                    previous[edge.to] = {
                        from = currentId,
                        connection = edge.source,
                        cost = edge.cost,
                    }
                end
            end
        end
    end

    if distances[goalId] == nil then
        return nil
    end

    local reversedIds = { goalId }
    local reversedLegs = {}
    local cursor = goalId
    for _ = 1, #surfaceById do
        if cursor == startId then
            break
        end
        local step = previous[cursor]
        if not step then
            return nil
        end
        reversedLegs[#reversedLegs + 1] = {
            from = step.from,
            to = cursor,
            relation = step.connection.relation,
            horizontalGap = step.connection.horizontalGap,
            verticalDelta = step.connection.verticalDelta,
            cost = step.cost,
            requiresValidation = true,
        }
        cursor = step.from
        reversedIds[#reversedIds + 1] = cursor
    end
    if cursor ~= startId then
        return nil
    end

    local surfaceIds = {}
    for index = #reversedIds, 1, -1 do
        surfaceIds[#surfaceIds + 1] = reversedIds[index]
    end
    local legs = {}
    for index = #reversedLegs, 1, -1 do
        legs[#legs + 1] = reversedLegs[index]
    end

    local uncertaintyTotal = 0
    for _, id in ipairs(surfaceIds) do
        uncertaintyTotal += uncertaintyById[id]
    end

    return {
        surfaceIds = surfaceIds,
        legs = legs,
        totalCost = distances[goalId],
        averageSurfaceUncertainty = uncertaintyTotal / #surfaceIds,
        legCount = #legs,
        isHypothetical = true,
        isGuaranteedReachable = false,
        requiresValidation = true,
    }
end

local function routeSignature(route)
    return table.concat(route.surfaceIds, ">")
end

function RouteLaboratory.new(options)
    return setmetatable({
        _options = validateOptions(options),
        _destroyed = false,
        _comparisonCount = 0,
    }, RouteLaboratory)
end

-- Compare hypothetical routes between two surface IDs in a validated L2 report.
-- Optional L3 confidence must have been integrated from this exact L2 report.
-- Optional stores may contain a caller-owned Foundation K DecisionLedger.
function RouteLaboratory:Compare(report, startId, goalId, confidence, stores, now)
    if self._destroyed then
        return nil, "Destroyed"
    end
    stores = stores or {}
    if type(stores) ~= "table" then
        return nil, "InvalidStores"
    end
    local currentTime = now or os.clock()
    if not isFiniteNumber(currentTime) then
        return nil, "InvalidTimestamp"
    end

    local valid, detailsOrReason = validateInputs(
        report, startId, goalId, confidence, self._options, currentTime
    )
    if not valid then
        return nil, detailsOrReason
    end
    local details = detailsOrReason
    local options = self._options
    local primary = shortestPath(
        details.surfaces, report.connections, details.uncertainty,
        options, startId, goalId, nil
    )

    local routes = {}
    if primary then
        routes[#routes + 1] = primary
        local seen = { [routeSignature(primary)] = true }
        -- Each bounded alternative excludes one edge from the primary route.
        -- This is a practical alternative generator, not an exhaustive K-shortest-path solver.
        for _, leg in ipairs(primary.legs) do
            if #routes >= options.maxRoutes then
                break
            end
            local alternative = shortestPath(
                details.surfaces, report.connections, details.uncertainty,
                options, startId, goalId, edgeKey(leg.from, leg.to)
            )
            if alternative then
                local signature = routeSignature(alternative)
                if not seen[signature] then
                    seen[signature] = true
                    routes[#routes + 1] = alternative
                end
            end
        end
        table.sort(routes, function(a, b)
            if a.totalCost == b.totalCost then
                return routeSignature(a) < routeSignature(b)
            end
            return a.totalCost < b.totalCost
        end)
        if #routes > options.maxRoutes then
            routes[options.maxRoutes + 1] = nil
        end
    end

    local status = #routes > 0 and "CandidatesFound" or "NoCandidateRoute"
    local decisionStatus = "NotRequested"
    if options.recordDecision then
        local ledger = stores.decisionLedger
        if ledger then
            local alternatives = {}
            for index = 2, math.min(#routes, 4) do
                alternatives[#alternatives + 1] = "AlternativeRoute" .. tostring(index)
            end
            if #alternatives == 0 then
                alternatives = { "FurtherSamplingRequired", "NoCandidateRoute" }
            end
            local success, result = ledger:Record({
                decisionType = "ExperimentalComparison",
                chosenOption = #routes > 0 and "LowestEstimatedCostCandidate" or "NoCandidateRoute",
                reason = #routes > 0
                    and "Compared bounded hypothetical geometry routes; movement remains unverified."
                    or "No directed candidate route connects the requested surfaces.",
                alternatives = alternatives,
                evidenceKeys = { "L2GeometryCandidates", "L3SpatialUncertainty" },
                confidenceScore = #routes > 0
                    and math.floor((1 - routes[1].averageSurfaceUncertainty) * 100 + 0.5) or nil,
                uncertainty = #routes > 0 and routes[1].averageSurfaceUncertainty or nil,
                timestamp = currentTime,
            })
            decisionStatus = result
            if not success and result == nil then
                decisionStatus = "Rejected"
            end
        else
            decisionStatus = "StoreMissing"
        end
    end

    self._comparisonCount += 1
    return {
        status = status,
        timestamp = currentTime,
        sourceTimestamp = report.timestamp,
        sourceAge = details.age,
        startSurfaceId = startId,
        goalSurfaceId = goalId,
        routes = routes,
        routeCount = #routes,
        confidenceSource = details.confidenceSource,
        isExhaustive = false,
        isMovementExecuted = false,
        decisionStatus = decisionStatus,
        limits = {
            isHeuristicCost = true,
            costIsProbability = false,
            guaranteesReachability = false,
            performsWorldQueries = false,
            executesMovement = false,
        },
        comparisonNumber = self._comparisonCount,
    }, status
end

function RouteLaboratory:GetComparisonCount()
    return self._comparisonCount
end

function RouteLaboratory:Destroy()
    self._destroyed = true
end

return RouteLaboratory
