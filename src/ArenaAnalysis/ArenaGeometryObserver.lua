-- Navigation Architecture v2.2
-- Foundation L1: ArenaGeometryObserver
-- Explicit, bounded, read-only geometry sampling around a supplied origin.
-- This module does not inspect players, tools, inventory, bomb state, or game objectives.

local ArenaGeometryObserver = {}
ArenaGeometryObserver.__index = ArenaGeometryObserver

local TWO_PI = math.pi * 2

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

    local radialSamples = options.radialSamples or 8
    local probeDistance = options.probeDistance or 16
    local obstructionHeights = options.obstructionHeights or { 1.5, 3.5 }
    local surfaceStartHeight = options.surfaceStartHeight or 6
    local surfaceDepth = options.surfaceDepth or 24
    local filterInstances = options.filterInstances or {}

    assert(isFiniteNumber(radialSamples) and radialSamples % 1 == 0
        and radialSamples >= 4 and radialSamples <= 16,
        "radialSamples must be an integer from 4 to 16")
    assert(isFiniteNumber(probeDistance) and probeDistance >= 4 and probeDistance <= 48,
        "probeDistance must be from 4 to 48 studs")
    assert(type(obstructionHeights) == "table" and #obstructionHeights == 2,
        "obstructionHeights must contain exactly two heights")
    for _, height in ipairs(obstructionHeights) do
        assert(isFiniteNumber(height) and height >= 0 and height <= 12,
            "obstruction heights must be from 0 to 12 studs")
    end
    assert(isFiniteNumber(surfaceStartHeight) and surfaceStartHeight >= 1
        and surfaceStartHeight <= 20, "surfaceStartHeight must be from 1 to 20 studs")
    assert(isFiniteNumber(surfaceDepth) and surfaceDepth >= 4 and surfaceDepth <= 64,
        "surfaceDepth must be from 4 to 64 studs")
    assert(type(filterInstances) == "table", "filterInstances must be a table")

    local lowHeight, highHeight = table.unpack(obstructionHeights)

    return {
        radialSamples = radialSamples,
        probeDistance = probeDistance,
        obstructionHeights = { lowHeight, highHeight },
        surfaceStartHeight = surfaceStartHeight,
        surfaceDepth = surfaceDepth,
        filterInstances = filterInstances,
        worldRoot = options.worldRoot or workspace,
    }
end

local function safeRaycast(worldRoot, origin, direction, params)
    if worldRoot == nil then
        return nil, false, "MissingWorldRoot"
    end
    local ok, result = pcall(function()
        return worldRoot:Raycast(origin, direction, params)
    end)
    if not ok then
        return nil, false, tostring(result)
    end
    return result, true, nil
end

local function describeHit(hit, originY)
    if not hit then
        return nil
    end
    return {
        position = hit.Position,
        normal = hit.Normal,
        distance = hit.Distance,
        material = hit.Material,
        elevationDelta = hit.Position.Y - originY,
    }
end

function ArenaGeometryObserver.new(options)
    local config = validateOptions(options)

    local self = setmetatable({
        _config = config,
        _worldRoot = config.worldRoot,
    }, ArenaGeometryObserver)

    return self
end

function ArenaGeometryObserver:setFilterInstances(instances)
    assert(type(instances) == "table", "instances must be a table")
    self._config.filterInstances = instances
end

function ArenaGeometryObserver:observe(origin, characterToExclude)
    assert(isFiniteVector3(origin), "origin must be a finite Vector3")

    local cfg = self._config
    local lowHeight, highHeight = table.unpack(cfg.obstructionHeights)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = cfg.filterInstances
    params.IgnoreWater = true

    if characterToExclude ~= nil then
        if typeof(characterToExclude) ~= "Instance" then
            return nil, "InvalidCharacterExclusion"
        end
        local ok = pcall(function()
            params.ExcludeInstances = { characterToExclude }
        end)
        if not ok then
            return nil, "CharacterExclusionFailed"
        end
    end

    local snapshot = {
        origin = origin,
        rayCount = 0,
        centerSurface = nil,
        sectors = table.create(cfg.radialSamples),
    }

    -- 1. Center probe directly beneath origin
    local centerOrigin = origin + Vector3.new(0, cfg.surfaceStartHeight, 0)
    local centerDirection = Vector3.new(0, -(cfg.surfaceStartHeight + cfg.surfaceDepth), 0)

    local centerHit, centerOk, centerReason = safeRaycast(self._worldRoot, centerOrigin, centerDirection, params)
    if not centerOk then
        return nil, "CenterProbeFailed:" .. centerReason
    end
    snapshot.rayCount += 1
    snapshot.centerSurface = describeHit(centerHit, origin.Y)

    -- 2. Radial sweep around origin
    for i = 1, cfg.radialSamples do
        local angle = ((i - 1) / cfg.radialSamples) * TWO_PI
        local dir = Vector3.new(math.cos(angle), 0, math.sin(angle))
        local rayDirection = dir * cfg.probeDistance

        local sector = {
            index = i,
            angle = angle,
            direction = dir,
            obstructionObserved = false,
            obstructionLowBlocked = nil,
            obstructionHighBlocked = nil,
            obstructionLow = nil,
            obstructionHigh = nil,
            surface = nil,
            clearDistance = cfg.probeDistance,
        }

        -- Low obstruction probe
        local lowOrigin = origin + Vector3.new(0, lowHeight, 0)
        local lowHit, lowOk, lowReason = safeRaycast(self._worldRoot, lowOrigin, rayDirection, params)
        if not lowOk then
            return nil, "LowObstructionProbeFailed:" .. lowReason
        end
        snapshot.rayCount += 1
        sector.obstructionLow = describeHit(lowHit, origin.Y)

        -- High obstruction probe
        local highOrigin = origin + Vector3.new(0, highHeight, 0)
        local highHit, highOk, highReason = safeRaycast(self._worldRoot, highOrigin, rayDirection, params)
        if not highOk then
            return nil, "HighObstructionProbeFailed:" .. highReason
        end
        snapshot.rayCount += 1
        sector.obstructionHigh = describeHit(highHit, origin.Y)

        sector.obstructionObserved = true
        sector.obstructionLowBlocked = lowHit ~= nil
        sector.obstructionHighBlocked = highHit ~= nil

        -- Determine unobstructed horizontal reach before probing downward
        local clearDistance = cfg.probeDistance
        if lowHit and lowHit.Distance < clearDistance then
            clearDistance = lowHit.Distance
        end
        if highHit and highHit.Distance < clearDistance then
            clearDistance = highHit.Distance
        end
        sector.clearDistance = clearDistance

        -- Surface probe (pulled back 0.5 studs from walls so downward ray doesn't clip inside geometry)
        local safeReach = math.max(0, clearDistance - 0.5)
        local surfaceOrigin = origin + (dir * safeReach) + Vector3.new(0, cfg.surfaceStartHeight, 0)
        local surfaceDirection = centerDirection

        local surfaceHit, surfaceOk, surfaceReason = safeRaycast(self._worldRoot, surfaceOrigin, surfaceDirection, params)
        if not surfaceOk then
            return nil, "SurfaceProbeFailed:" .. surfaceReason
        end
        snapshot.rayCount += 1
        sector.surface = describeHit(surfaceHit, origin.Y)

        snapshot.sectors[i] = sector
    end

    return snapshot
end

return ArenaGeometryObserver
