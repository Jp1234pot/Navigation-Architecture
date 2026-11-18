-- Navigation Architecture v2.2
-- Foundation L2: ReachabilityAnalyzer
-- Pure, bounded analysis of a Foundation L1 geometry snapshot.
-- This module does not raycast, scan players, move characters, or execute routes.

local ReachabilityAnalyzer = {}
ReachabilityAnalyzer.__index = ReachabilityAnalyzer

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
        maxSnapshotAge = options.maxSnapshotAge or 5,
        maxWalkGap = options.maxWalkGap or 5,
        maxStepHeight = options.maxStepHeight or 2.5,
        maxJumpHorizontalDistance = options.maxJumpHorizontalDistance or 20,
        maxJumpRise = options.maxJumpRise or 7.5,
        maxDropHeight = options.maxDropHeight or 12,
        minSurfaceNormalY = options.minSurfaceNormalY or 0.65,
        maxSurfaces = options.maxSurfaces or 17,
        dedupeDistance = options.dedupeDistance or 1.5,
    }

    assert(isFiniteNumber(result.maxSnapshotAge) and result.maxSnapshotAge >= 0.25
        and result.maxSnapshotAge <= 30, "maxSnapshotAge must be from 0.25 to 30 seconds")
    assert(isFiniteNumber(result.maxWalkGap) and result.maxWalkGap >= 1
        and result.maxWalkGap <= 8, "maxWalkGap must be from 1 to 8 studs")
    assert(isFiniteNumber(result.maxStepHeight) and result.maxStepHeight >= 0.5
        and result.maxStepHeight <= 4, "maxStepHeight must be from 0.5 to 4 studs")
    assert(isFiniteNumber(result.maxJumpHorizontalDistance) and result.maxJumpHorizontalDistance >= 4
        and result.maxJumpHorizontalDistance <= 32,
        "maxJumpHorizontalDistance must be from 4 to 32 studs")
    assert(isFiniteNumber(result.maxJumpRise) and result.maxJumpRise >= 1
        and result.maxJumpRise <= 12, "maxJumpRise must be from 1 to 12 studs")
    assert(isFiniteNumber(result.maxDropHeight) and result.maxDropHeight >= 1
        and result.maxDropHeight <= 24, "maxDropHeight must be from 1 to 24 studs")
    assert(isFiniteNumber(result.minSurfaceNormalY) and result.minSurfaceNormalY >= 0.5
        and result.minSurfaceNormalY <= 0.95,
        "minSurfaceNormalY must be from 0.5 to 0.95")
    assert(isFiniteNumber(result.maxSurfaces) and result.maxSurfaces % 1 == 0
        and result.maxSurfaces >= 1 and result.maxSurfaces <= 17,
        "maxSurfaces must be an integer from 1 to 17")
    assert(isFiniteNumber(result.dedupeDistance) and result.dedupeDistance >= 0
        and result.dedupeDistance <= 4, "dedupeDistance must be from 0 to 4 studs")

    return result
end

local function horizontalDistance(a, b)
    local dx = b.X - a.X
    local dz = b.Z - a.Z
    return math.sqrt(dx * dx + dz * dz)
end

local function isUsableSurface(hit)
    return type(hit) == "table"
        and isFiniteVector3(hit.position)
        and isFiniteVector3(hit.normal)
end

-- [A] Added helper function below isUsableSurface
local function isSectorPathClear(sector)
    return type(sector) == "table"
        and sector.obstructionObserved == true
        and sector.obstructionLowBlocked == false
        and sector.obstructionHighBlocked == false
end

-- [B] Modified addSurface to return existing or newly created surface
local function addSurface(surfaces, hit, source)
    if not isUsableSurface(hit) then
        return nil
    end

    for _, existing in ipairs(surfaces) do
        if existing.instance == hit.instance
            and (existing.position - hit.position).Magnitude <= source.dedupeDistance then
            existing.sources[#existing.sources + 1] = source.label
            return existing
        end
    end

    local created = {
        id = "Surface" .. tostring(#surfaces + 1),
        instance = hit.instance,
        position = hit.position,
        normal = hit.normal,
        material = type(hit.material) == "string" and hit.material or "Unknown",
        sources = { source.label },
        sectorIndex = source.sectorIndex,
    }

    surfaces[#surfaces + 1] = created
    return created
end

local function surfaceIsWalkableCandidate(surface, minimumNormalY)
    return surface.normal.Y >= minimumNormalY
end

local function classifyPair(a, b, options)
    local horizontalGap = horizontalDistance(a.position, b.position)
    local verticalDelta = b.position.Y - a.position.Y
    local absoluteVerticalDelta = math.abs(verticalDelta)

    if not surfaceIsWalkableCandidate(a, options.minSurfaceNormalY)
        or not surfaceIsWalkableCandidate(b, options.minSurfaceNormalY) then
        return nil
    end

    local relation = nil
    if horizontalGap <= options.maxWalkGap
        and absoluteVerticalDelta <= options.maxStepHeight then
        relation = "WalkCandidate"
    elseif horizontalGap <= options.maxJumpHorizontalDistance
        and verticalDelta > options.maxStepHeight
        and verticalDelta <= options.maxJumpRise then
        relation = "JumpCandidate"
    elseif horizontalGap <= options.maxJumpHorizontalDistance
        and verticalDelta < -options.maxStepHeight
        and -verticalDelta <= options.maxDropHeight then
        relation = "DropCandidate"
    elseif horizontalGap > options.maxWalkGap
        and horizontalGap <= options.maxJumpHorizontalDistance
        and absoluteVerticalDelta <= options.maxStepHeight then
        relation = "JumpCandidate"
    end

    if not relation then
        return nil
    end

    return {
        from = a.id,
        to = b.id,
        relation = relation,
        horizontalGap = horizontalGap,
        verticalDelta = verticalDelta,
        sourceNormalY = a.normal.Y,
        destinationNormalY = b.normal.Y,
        requiresValidation = true,
        isGuaranteedReachable = false,
    }
end

function ReachabilityAnalyzer.new(options)
    return setmetatable({
        _options = validateOptions(options),
        _destroyed = false,
        _analysisCount = 0,
    }, ReachabilityAnalyzer)
end

-- [C] Replaced Analyze() function
function ReachabilityAnalyzer:Analyze(snapshot, now)
    if self._destroyed then
        return nil, "Destroyed"
    end
    if type(snapshot) ~= "table"
        or not isFiniteVector3(snapshot.origin)
        or not isFiniteNumber(snapshot.timestamp)
        or type(snapshot.sectors) ~= "table"
        or not isFiniteNumber(snapshot.radialSamples)
        or snapshot.radialSamples % 1 ~= 0
        or snapshot.radialSamples < 4
        or snapshot.radialSamples > 16 then
        return nil, "InvalidSnapshot"
    end

    local currentTime = now or os.clock()
    if not isFiniteNumber(currentTime) then
        return nil, "InvalidTimestamp"
    end

    local age = currentTime - snapshot.timestamp
    if not isFiniteNumber(age) or age < 0 then
        return nil, "InvalidTimestamp"
    end
    if age > self._options.maxSnapshotAge then
        return nil, "StaleSnapshot"
    end

    local options = self._options
    local expectedSectorCount = snapshot.radialSamples
    if #snapshot.sectors > expectedSectorCount then
        return nil, "SectorLimitExceeded"
    end

    local surfaces = {}
    local centerSurface = nil
    local unobservedSectorCount = 0
    local blockedSectorCount = 0
    local unverifiedConnectionSectorCount = 0

    centerSurface = addSurface(surfaces, snapshot.centerSurface, {
        label = "Center",
        sectorIndex = nil,
        dedupeDistance = options.dedupeDistance,
    })

    local connections = {}
    local pairComparisons = 0

    for index = 1, expectedSectorCount do
        local sector = snapshot.sectors[index]
        if type(sector) ~= "table" then
            unobservedSectorCount += 1
            unverifiedConnectionSectorCount += 1
            continue
        end

        local sectorIndex = sector.index
        if not isFiniteNumber(sectorIndex) or sectorIndex % 1 ~= 0 or sectorIndex ~= index then
            return nil, "InvalidSectorIndex"
        end

        local sectorSurface = nil
        if isUsableSurface(sector.surface) then
            sectorSurface = addSurface(surfaces, sector.surface, {
                label = "Sector" .. tostring(index),
                sectorIndex = index,
                dedupeDistance = options.dedupeDistance,
            })
        else
            unobservedSectorCount += 1
        end

        if not isSectorPathClear(sector) then
            if sector.obstructionObserved == true then
                blockedSectorCount += 1
            else
                unverifiedConnectionSectorCount += 1
            end
            continue
        end

        if not centerSurface or not sectorSurface then
            continue
        end

        pairComparisons += 1
        local connection = classifyPair(
            centerSurface,
            sectorSurface,
            options
        )
        if connection then
            connection.connectionEvidence = "RadialObstructionProbesClear"
            connection.requiresValidation = true
            connection.isGuaranteedReachable = false
            connections[#connections + 1] = connection
        end
    end

    if #surfaces > options.maxSurfaces then
        return nil, "SurfaceLimitExceeded"
    end

    self._analysisCount += 1
    local status = "Success"
    if #surfaces == 0 then
        status = "NoSurfaceObservations"
    elseif #connections == 0 then
        status = "NoCandidateConnections"
    end

    return {
        status = status,
        timestamp = currentTime,
        sourceTimestamp = snapshot.timestamp,
        sourceAge = age,
        surfaces = surfaces,
        connections = connections,
        surfaceCount = #surfaces,
        connectionCount = #connections,
        pairComparisons = pairComparisons,
        expectedSectorCount = expectedSectorCount,
        unobservedSectorCount = unobservedSectorCount,
        blockedSectorCount = blockedSectorCount,
        unverifiedConnectionSectorCount = unverifiedConnectionSectorCount,
        analysisNumber = self._analysisCount,
        limits = {
            isHeuristic = true,
            isProbability = false,
            guaranteesReachability = false,
            usesCharacterJumpSettings = false,
            performsWorldQueries = false,
            usesOnlyRadialConnections = true,
            crossSectorConnectionsVerified = false,
        },
    }, status
end

function ReachabilityAnalyzer:GetAnalysisCount()
    return self._analysisCount
end

function ReachabilityAnalyzer:Destroy()
    self._destroyed = true
end

return ReachabilityAnalyzer
