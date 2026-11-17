-- Navigation Architecture v2.2
-- Unified configuration for the L1-L5 Arena Analysis subsystem.
-- Module-level constructors remain responsible for validating their own bounds.

local ArenaAnalysisConfig = {}

local DEFAULTS = {
    enableSpatialConfidence = true,
    enableFeasibility = true,
    observer = {
        radialSamples = 8,
        probeDistance = 16,
        obstructionHeights = { 1.5, 3.5 },
        surfaceStartHeight = 6,
        surfaceDepth = 24,
    },
    reachability = {
        maxSnapshotAge = 5,
        maxWalkGap = 5,
        maxStepHeight = 2.5,
        maxJumpHorizontalDistance = 20,
        maxJumpRise = 7.5,
        maxDropHeight = 12,
        minSurfaceNormalY = 0.65,
        maxSurfaces = 17,
        dedupeDistance = 1.5,
    },
    confidence = {
        maxReportAge = 5,
        maxSurfaces = 17,
        maxConnections = 136,
        maxUnobservedSectors = 16,
        ageWeight = 0.4,
        coverageWeight = 0.6,
        uncertaintyReason = "Spatial observation coverage estimate",
        recordEvidence = false,
        recordDecision = false,
    },
    route = {
        maxReportAge = 5,
        maxSurfaces = 17,
        maxConnections = 136,
        maxRoutes = 3,
        verticalWeight = 1.25,
        uncertaintyPenalty = 8,
        walkPenalty = 0,
        jumpPenalty = 2,
        dropPenalty = 1.5,
        defaultUncertainty = 0.5,
        recordDecision = false,
    },
    feasibility = {
        maxLegs = 16,
    },
}

local function cloneValue(value)
    if type(value) ~= "table" then
        return value
    end
    local copy = {}
    for key, child in pairs(value) do
        copy[key] = cloneValue(child)
    end
    return copy
end

local function mergeKnown(target, source, path)
    assert(type(source) == "table", path .. " must be a table")
    for key, value in pairs(source) do
        assert(target[key] ~= nil, "unknown configuration key: " .. path .. "." .. tostring(key))
        if type(target[key]) == "table" then
            mergeKnown(target[key], value, path .. "." .. tostring(key))
        else
            target[key] = value
        end
    end
end

function ArenaAnalysisConfig.Create(overrides)
    local config = cloneValue(DEFAULTS)
    if overrides ~= nil then
        assert(type(overrides) == "table", "overrides must be a table")
        mergeKnown(config, overrides, "config")
    end

    assert(type(config.enableSpatialConfidence) == "boolean",
        "enableSpatialConfidence must be boolean")
    assert(type(config.enableFeasibility) == "boolean", "enableFeasibility must be boolean")
    return config
end

return ArenaAnalysisConfig
