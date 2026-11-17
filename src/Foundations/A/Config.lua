
-- Navigation Architecture v2.2
-- Module: Config
-- Client-only configuration defaults and validated override construction.

local Config = {}

local DEFAULTS = {
    enabled = false,
    targetMode = "Player",
    behaviorMode = "Pursue",

    stoppingDistance = 3.0,
    momentumTolerance = 1.5,

    -- Discovery intervals are currently reserved settings.
    -- TargetDiscovery does not schedule its own scans.
    playerScanInterval = 0.50,
    npcScanInterval = 0.85,
    scannerWakeInterval = 0.10,

    pathComputeInterval = 0.75,
    stuckCheckInterval = 0.80,
    stuckDisplacementThreshold = 0.45,
    waypointReachedDistance = 2.75,
    climbWaypointReachedDistance = 3.5,
    maxWaypointVerticalError = 5.0,
    targetRepathDistance = 8.0,
    reassessmentDelta = 5.0,

    maxRetries = 3,
    retryCooldown = 2.5,
    retryResetAfterProgress = 3.0,

    agentRadius = 2.0,
    agentHeight = 5.0,
    agentCanJump = true,
    agentCanClimb = true,
    waypointSpacing = 4.0,
    pathCosts = {},

    npcFolderName = "NPCs",
    allowUnclassifiedNPCs = true,
    factionAttribute = "Faction",
    npcTargetAttribute = nil,

    autoJumpWhenStuck = false,
    groundWaitTimeout = 0.75,
    velocityApproachMultiplier = 0.0625,

    velocitySmoothingAlpha = 0.35,
    minVelocitySampleDelta = 1 / 240,
    maxVelocitySampleGap = 1.0,

    -- Foundation D: local and selected-target sampling.
    -- 0.05 seconds = 20 Hz.
    telemetrySampleInterval = 0.05,
    telemetryPanelEnabled = true,

    pathfindingEnabled = false,

    -- Foundation F: minimum gap between accepted path requests.
    -- This is NOT an automatic path-request timer.
    pathRequestMinInterval = 0.20,

    movementEnabled = false,
    movementSegmentTimeout = 8.5,
    movementRouteTimeout = 300.0,

    adaptiveRepathEnabled = false,

    -- Foundation I: repath authorization limits.
    adaptiveRepathMinInterval = 0.50,
    adaptiveRepathWindowSeconds = 60.0,
    adaptiveRepathMaxRequestsPerWindow = 20,
    adaptiveRepathMaxBackoff = 16.0,
    adaptiveRepathTargetDistance = 8.0,
    adaptiveRepathCircuitBreakAfter = 3,
    adaptiveRepathCircuitBreakSeconds = 20.0,
    maxRecoveryRecords = 100,

    multiThreatAnalysisEnabled = false,

    -- Foundation J: multi-threat analysis.
    -- 0.10 seconds = 10 Hz.
    threatAnalysisMinInterval = 0.10,
    maxThreatCandidates = 32,
    maxThreatResults = 16,
    threatPredictionHorizon = 3.0,
    threatNearDistance = 18.0,
    threatCriticalDistance = 8.0,
    threatMaxEstimateAge = 0.75,
    threatMaxApproachSpeed = 24.0,

    -- Foundation K: bounded evidence and explanation records.
    evidenceLedgerEnabled = false,
    maxEvidenceRecords = 128,
    evidenceMaxAge = 30.0,
    evidenceHalfLife = 10.0,
    evidenceMinSamples = 3,

    uncertaintyCellSize = 32.0,
    maxUncertaintyCells = 128,
    uncertaintyMaxAge = 30.0,

    maxDecisionRecords = 100,

    maxTrackedWaypoints = 512,
    maxWaypointAdvancesPerUpdate = 4,
    maxNpcCandidatesToInspect = 256,

    maxSessionRecords = 250,
}

local KNOWN_KEYS = {}

for key in pairs(DEFAULTS) do
    KNOWN_KEYS[key] = true
end

KNOWN_KEYS.npcTargetAttribute = true

local VALIDATORS = {
    enabled = function(value) return type(value) == "boolean" end,
    targetMode = function(value) return value == "Player" or value == "NPC" end,
    behaviorMode = function(value) return value == "Pursue" or value == "Escape" end,
    agentCanJump = function(value) return type(value) == "boolean" end,
    agentCanClimb = function(value) return type(value) == "boolean" end,
    allowUnclassifiedNPCs = function(value) return type(value) == "boolean" end,
    autoJumpWhenStuck = function(value) return type(value) == "boolean" end,
    telemetryPanelEnabled = function(value) return type(value) == "boolean" end,
    pathfindingEnabled = function(value) return type(value) == "boolean" end,
    movementEnabled = function(value) return type(value) == "boolean" end,
    adaptiveRepathEnabled = function(value) return type(value) == "boolean" end,
    multiThreatAnalysisEnabled = function(value) return type(value) == "boolean" end,
    evidenceLedgerEnabled = function(value) return type(value) == "boolean" end,
    pathCosts = function(value) return type(value) == "table" end,
    npcFolderName = function(value) return value == nil or type(value) == "string" end,
    factionAttribute = function(value) return type(value) == "string" and value ~= "" end,
    npcTargetAttribute = function(value)
        return value == nil or (type(value) == "string" and value ~= "")
    end,
}

local POSITIVE_NUMBERS = {
    stoppingDistance = true,
    playerScanInterval = true,
    npcScanInterval = true,
    scannerWakeInterval = true,
    pathComputeInterval = true,
    stuckCheckInterval = true,
    stuckDisplacementThreshold = true,
    waypointReachedDistance = true,
    climbWaypointReachedDistance = true,
    maxWaypointVerticalError = true,
    targetRepathDistance = true,
    reassessmentDelta = true,
    retryCooldown = true,
    retryResetAfterProgress = true,
    agentRadius = true,
    agentHeight = true,
    waypointSpacing = true,
    groundWaitTimeout = true,
    maxSessionRecords = true,
    minVelocitySampleDelta = true,
    maxVelocitySampleGap = true,
    telemetrySampleInterval = true,
    pathRequestMinInterval = true,
    movementSegmentTimeout = true,
    movementRouteTimeout = true,
    adaptiveRepathMinInterval = true,
    adaptiveRepathWindowSeconds = true,
    adaptiveRepathMaxBackoff = true,
    adaptiveRepathTargetDistance = true,
    adaptiveRepathCircuitBreakSeconds = true,
    maxTrackedWaypoints = true,
    maxWaypointAdvancesPerUpdate = true,
    maxNpcCandidatesToInspect = true,
    adaptiveRepathMaxRequestsPerWindow = true,
    adaptiveRepathCircuitBreakAfter = true,
    maxRecoveryRecords = true,
    threatAnalysisMinInterval = true,
    maxThreatCandidates = true,
    maxThreatResults = true,
    threatPredictionHorizon = true,
    threatNearDistance = true,
    threatCriticalDistance = true,
    threatMaxEstimateAge = true,
    threatMaxApproachSpeed = true,

    -- Foundation K positive numeric settings.
    evidenceMaxAge = true,
    evidenceHalfLife = true,
    uncertaintyCellSize = true,
    uncertaintyMaxAge = true,
}

local NON_NEGATIVE_NUMBERS = {
    momentumTolerance = true,
    velocityApproachMultiplier = true,
}

local function isFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function copyTable(source)
    local result = {}

    for key, value in pairs(source) do
        if type(value) == "table" then
            result[key] = copyTable(value)
        else
            result[key] = value
        end
    end

    return result
end

function Config.Create(overrides)
    assert(
        overrides == nil or type(overrides) == "table",
        "Config overrides must be a table"
    )

    local result = copyTable(DEFAULTS)

    if overrides then
        local overrideCount = 0

        for key, value in pairs(overrides) do
            overrideCount += 1

            assert(
                overrideCount <= 64,
                "Config overrides may contain at most 64 entries"
            )

            assert(
                KNOWN_KEYS[key],
                string.format("Unknown navigation config key: %s", tostring(key))
            )

            if key == "pathCosts" then
                assert(type(value) == "table", "config.pathCosts must be a table")

                local copiedCosts = {}
                local costCount = 0

                for costKey, costValue in pairs(value) do
                    costCount += 1

                    assert(
                        costCount <= 128,
                        "config.pathCosts may contain at most 128 entries"
                    )

                    copiedCosts[costKey] = costValue
                end

                result[key] = copiedCosts
            else
                result[key] = value
            end
        end
    end

    for key, validator in pairs(VALIDATORS) do
        assert(
            validator(result[key]),
            string.format("Invalid value for config.%s", key)
        )
    end

    for key in pairs(POSITIVE_NUMBERS) do
        local value = result[key]

        assert(
            isFiniteNumber(value) and value > 0,
            string.format("config.%s must be finite and > 0", key)
        )
    end

    for key in pairs(NON_NEGATIVE_NUMBERS) do
        local value = result[key]

        assert(
            isFiniteNumber(value) and value >= 0,
            string.format("config.%s must be finite and >= 0", key)
        )
    end

    assert(
        result.telemetrySampleInterval >= 0.05
            and result.telemetrySampleInterval <= 2.0,
        "config.telemetrySampleInterval must be between 0.05 and 2.0 seconds"
    )

    assert(
        result.pathRequestMinInterval >= 0.1
            and result.pathRequestMinInterval <= 5.0,
        "config.pathRequestMinInterval must be between 0.1 and 5.0 seconds"
    )

    assert(
        result.movementSegmentTimeout >= 8.1
            and result.movementSegmentTimeout <= 15.0,
        "config.movementSegmentTimeout must be between 8.1 and 15.0 seconds"
    )

    assert(
        result.movementRouteTimeout >= 30
            and result.movementRouteTimeout <= 900,
        "config.movementRouteTimeout must be between 30 and 900 seconds"
    )

    assert(
        result.adaptiveRepathMinInterval >= 0.5
            and result.adaptiveRepathMinInterval <= 30,
        "config.adaptiveRepathMinInterval must be between 0.5 and 30 seconds"
    )

    assert(
        result.adaptiveRepathWindowSeconds >= 10
            and result.adaptiveRepathWindowSeconds <= 600,
        "config.adaptiveRepathWindowSeconds must be between 10 and 600 seconds"
    )

    assert(
        result.adaptiveRepathMaxBackoff >= result.adaptiveRepathMinInterval
            and result.adaptiveRepathMaxBackoff <= 120,
        "config.adaptiveRepathMaxBackoff must be >= min interval and <= 120 seconds"
    )

    assert(
        result.adaptiveRepathTargetDistance >= 1
            and result.adaptiveRepathTargetDistance <= 100,
        "config.adaptiveRepathTargetDistance must be between 1 and 100 studs"
    )

    assert(
        result.adaptiveRepathCircuitBreakSeconds >= 1
            and result.adaptiveRepathCircuitBreakSeconds <= 300,
        "config.adaptiveRepathCircuitBreakSeconds must be between 1 and 300 seconds"
    )

    assert(
        result.maxTrackedWaypoints % 1 == 0
            and result.maxTrackedWaypoints >= 1
            and result.maxTrackedWaypoints <= 2048,
        "config.maxTrackedWaypoints must be an integer from 1 to 2048"
    )

    assert(
        result.maxWaypointAdvancesPerUpdate % 1 == 0
            and result.maxWaypointAdvancesPerUpdate >= 1
            and result.maxWaypointAdvancesPerUpdate <= 32,
        "config.maxWaypointAdvancesPerUpdate must be an integer from 1 to 32"
    )

    assert(
        result.maxNpcCandidatesToInspect % 1 == 0
            and result.maxNpcCandidatesToInspect >= 1
            and result.maxNpcCandidatesToInspect <= 2048,
        "config.maxNpcCandidatesToInspect must be an integer from 1 to 2048"
    )

    assert(
        result.threatAnalysisMinInterval >= 0.1
            and result.threatAnalysisMinInterval <= 5.0,
        "config.threatAnalysisMinInterval must be between 0.1 and 5.0 seconds"
    )

    assert(
        result.maxThreatCandidates % 1 == 0
            and result.maxThreatCandidates >= 1
            and result.maxThreatCandidates <= 64,
        "config.maxThreatCandidates must be an integer from 1 to 64"
    )

    assert(
        result.maxThreatResults % 1 == 0
            and result.maxThreatResults >= 1
            and result.maxThreatResults <= result.maxThreatCandidates,
        "config.maxThreatResults must be an integer from 1 to maxThreatCandidates"
    )

    assert(
        result.threatNearDistance <= 250,
        "config.threatNearDistance must be <= 250 studs"
    )

    assert(
        result.threatCriticalDistance < result.threatNearDistance,
        "config.threatCriticalDistance must be less than threatNearDistance"
    )

    assert(
        result.threatPredictionHorizon <= 10,
        "config.threatPredictionHorizon must be <= 10 seconds"
    )

    assert(
        result.threatMaxEstimateAge <= 2,
        "config.threatMaxEstimateAge must be <= 2 seconds"
    )

    assert(
        result.threatMaxApproachSpeed <= 250,
        "config.threatMaxApproachSpeed must be <= 250 studs/second"
    )

    -- Foundation K capacity and sample bounds.
    assert(
        result.maxEvidenceRecords % 1 == 0
            and result.maxEvidenceRecords >= 1
            and result.maxEvidenceRecords <= 512,
        "config.maxEvidenceRecords must be an integer from 1 to 512"
    )

    assert(
        result.evidenceMinSamples % 1 == 0
            and result.evidenceMinSamples >= 1
            and result.evidenceMinSamples <= 16,
        "config.evidenceMinSamples must be an integer from 1 to 16"
    )

    assert(
        result.uncertaintyCellSize >= 4,
        "config.uncertaintyCellSize must be at least 4"
    )

    assert(
        result.maxUncertaintyCells % 1 == 0
            and result.maxUncertaintyCells >= 1
            and result.maxUncertaintyCells <= 256,
        "config.maxUncertaintyCells must be an integer from 1 to 256"
    )

    assert(
        result.maxDecisionRecords % 1 == 0
            and result.maxDecisionRecords >= 1
            and result.maxDecisionRecords <= 256,
        "config.maxDecisionRecords must be an integer from 1 to 256"
    )

    assert(
        result.agentRadius % 1 == 0
            and result.agentHeight % 1 == 0,
        "config.agentRadius and config.agentHeight must be whole numbers"
    )

    local pathCostCount = 0

    for key, cost in pairs(result.pathCosts) do
        pathCostCount += 1

        assert(
            pathCostCount <= 128,
            "config.pathCosts may contain at most 128 entries"
        )

        assert(
            type(key) == "string" and key ~= "",
            "config.pathCosts keys must be non-empty strings"
        )

        assert(
            type(cost) == "number"
                and cost > 0
                and cost == cost
                and cost ~= -math.huge,
            "config.pathCosts values must be positive numbers or math.huge"
        )
    end

    assert(
        isFiniteNumber(result.velocitySmoothingAlpha)
            and result.velocitySmoothingAlpha > 0
            and result.velocitySmoothingAlpha <= 1,
        "config.velocitySmoothingAlpha must be in (0, 1]"
    )

    assert(
        isFiniteNumber(result.maxRetries)
            and result.maxRetries >= 0
            and result.maxRetries <= 10
            and result.maxRetries % 1 == 0,
        "config.maxRetries must be an integer from 0 to 10"
    )

    assert(
        isFiniteNumber(result.maxSessionRecords)
            and result.maxSessionRecords % 1 == 0
            and result.maxSessionRecords >= 1
            and result.maxSessionRecords <= 5000,
        "config.maxSessionRecords must be an integer from 1 to 5000"
    )

    assert(
        result.adaptiveRepathMaxRequestsPerWindow % 1 == 0
            and result.adaptiveRepathMaxRequestsPerWindow >= 1
            and result.adaptiveRepathMaxRequestsPerWindow <= 30,
        "config.adaptiveRepathMaxRequestsPerWindow must be an integer from 1 to 30"
    )

    assert(
        result.adaptiveRepathCircuitBreakAfter % 1 == 0
            and result.adaptiveRepathCircuitBreakAfter >= 1
            and result.adaptiveRepathCircuitBreakAfter <= 10,
        "config.adaptiveRepathCircuitBreakAfter must be an integer from 1 to 10"
    )

    assert(
        result.maxRecoveryRecords % 1 == 0
            and result.maxRecoveryRecords >= 1
            and result.maxRecoveryRecords <= 1000,
        "config.maxRecoveryRecords must be an integer from 1 to 1000"
    )

    return result
end

function Config.GetDefaults()
    return copyTable(DEFAULTS)
end

return Config
