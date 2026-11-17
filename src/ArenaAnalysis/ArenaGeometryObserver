-- Navigation Architecture v2.2
-- Foundation L1: ArenaGeometryObserver
-- Explicit, bounded, read-only geometry sampling around a supplied origin.
-- This module does not inspect players, tools, inventory, bomb state, or game objectives.

local ArenaGeometryObserver = {}
ArenaGeometryObserver.__index = ArenaGeometryObserver

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

    return {
        radialSamples = radialSamples,
        probeDistance = probeDistance,
        obstructionHeights = { obstructionHeights[1], obstructionHeights[2] },
        surfaceStartHeight = surfaceStartHeight,
        surfaceDepth = surfaceDepth,
    }
end

local function describeHit(result, originY)
    if not result then
        return nil
    end

    local instance = result.Instance
    return {
        instance = instance,
        position = result.Position,
        normal = result.Normal,
        material = result.Material.Name,
        distance = result.Distance,
        heightDelta = result.Position.Y - originY,
        isTerrain = instance == workspace.Terrain,
    }
end

function ArenaGeometryObserver.new(worldRoot, options)
    assert(worldRoot and type(worldRoot.Raycast) == "function",
        "ArenaGeometryObserver requires a WorldRoot such as Workspace")

    return setmetatable({
        _worldRoot = worldRoot,
        _options = validateOptions(options),
        _destroyed = false,
        _scanCount = 0,
    }, ArenaGeometryObserver)
end

-- Scan is deliberately caller-invoked. It performs one center ground probe and
-- three probes per radial direction, then returns a snapshot. It never moves
-- the character or creates a background loop.
function ArenaGeometryObserver:Scan(origin, characterToExclude)
    if self._destroyed then
        return nil, "Destroyed"
    end
    if not isFiniteVector3(origin) then
        return nil, "InvalidOrigin"
    end

    local options = self._options
    local params = RaycastParams.new()
    params.IgnoreWater = true
    params.RespectCanCollide = true
    if characterToExclude then
        params.ExcludeInstances = { characterToExclude }
    end

    local snapshot = {
        origin = origin,
        timestamp = os.clock(),
        centerSurface = nil,
        sectors = {},
        rayCount = 0,
        radialSamples = options.radialSamples,
    }

    local centerOrigin = origin + Vector3.new(0, options.surfaceStartHeight, 0)
    local centerDirection = Vector3.new(0, -options.surfaceStartHeight - options.surfaceDepth, 0)
    local centerHit = self._worldRoot:Raycast(centerOrigin, centerDirection, params)
    snapshot.rayCount += 1
    snapshot.centerSurface = describeHit(centerHit, origin.Y)

    for index = 1, options.radialSamples do
        local angle = ((index - 1) / options.radialSamples) * math.pi * 2
        local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
        local endpoint = origin + direction * options.probeDistance
        local sector = {
            index = index,
            direction = direction,
            obstructionLow = nil,
            obstructionHigh = nil,
            surface = nil,
        }

        local lowOrigin = origin + Vector3.new(0, options.obstructionHeights[1], 0)
        local highOrigin = origin + Vector3.new(0, options.obstructionHeights[2], 0)
        local rayDirection = direction * options.probeDistance

        local lowHit = self._worldRoot:Raycast(lowOrigin, rayDirection, params)
        snapshot.rayCount += 1
        sector.obstructionLow = describeHit(lowHit, origin.Y)

        local highHit = self._worldRoot:Raycast(highOrigin, rayDirection, params)
        snapshot.rayCount += 1
        sector.obstructionHigh = describeHit(highHit, origin.Y)

        local surfaceOrigin = endpoint + Vector3.new(0, options.surfaceStartHeight, 0)
        local surfaceDirection = Vector3.new(0, -options.surfaceStartHeight - options.surfaceDepth, 0)
        local surfaceHit = self._worldRoot:Raycast(surfaceOrigin, surfaceDirection, params)
        snapshot.rayCount += 1
        sector.surface = describeHit(surfaceHit, origin.Y)

        table.insert(snapshot.sectors, sector)
    end

    self._scanCount += 1
    snapshot.scanNumber = self._scanCount
    return snapshot, "Success"
end

function ArenaGeometryObserver:GetScanCount()
    return self._scanCount
end

function ArenaGeometryObserver:Destroy()
    self._destroyed = true
    self._worldRoot = nil
end

return ArenaGeometryObserver
