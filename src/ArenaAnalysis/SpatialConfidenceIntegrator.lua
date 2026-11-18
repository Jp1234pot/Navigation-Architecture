-- Navigation Architecture v2.2
-- Foundation L3: SpatialConfidenceIntegrator
-- Explicitly integrates a Foundation L2 report with optional Foundation K stores.
-- No world access, scanning, raycasts, scheduling, movement, or automatic writes.

local SpatialConfidenceIntegrator = {}
SpatialConfidenceIntegrator.__index = SpatialConfidenceIntegrator

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

local function clamp01(value)
    return math.max(0, math.min(1, value))
end

local function validateOptions(options)
    options = options or {}
    assert(type(options) == "table", "options must be a table")

    local result = {
        maxReportAge = options.maxReportAge or 5,
        maxSurfaces = options.maxSurfaces or 17,
        -- [A] Updated default maxConnections to 16
        maxConnections = options.maxConnections or 16,
        maxUnobservedSectors = options.maxUnobservedSectors or 16,
        ageWeight = options.ageWeight or 0.4,
        coverageWeight = options.coverageWeight or 0.6,
        uncertaintyReason = options.uncertaintyReason or "Spatial observation coverage estimate",
        recordEvidence = options.recordEvidence == true,
        recordDecision = options.recordDecision == true,
    }

    assert(isFiniteNumber(result.maxReportAge) and result.maxReportAge >= 0.25
        and result.maxReportAge <= 30, "maxReportAge must be from 0.25 to 30 seconds")
    assert(isFiniteNumber(result.maxSurfaces) and result.maxSurfaces % 1 == 0
        and result.maxSurfaces >= 1 and result.maxSurfaces <= 17,
        "maxSurfaces must be an integer from 1 to 17")
    -- [B] Updated validation limit and error message for maxConnections (0 to 16)
    assert(isFiniteNumber(result.maxConnections) and result.maxConnections % 1 == 0
        and result.maxConnections >= 0 and result.maxConnections <= 16,
        "maxConnections must be an integer from 0 to 16")
    assert(isFiniteNumber(result.maxUnobservedSectors) and result.maxUnobservedSectors % 1 == 0
        and result.maxUnobservedSectors >= 1 and result.maxUnobservedSectors <= 16,
        "maxUnobservedSectors must be an integer from 1 to 16")
    assert(isFiniteNumber(result.ageWeight) and result.ageWeight >= 0 and result.ageWeight <= 1,
        "ageWeight must be from 0 to 1")
    assert(isFiniteNumber(result.coverageWeight) and result.coverageWeight >= 0
        and result.coverageWeight <= 1, "coverageWeight must be from 0 to 1")
    assert(math.abs(result.ageWeight + result.coverageWeight - 1) <= 0.000001,
        "ageWeight and coverageWeight must sum to 1")
    assert(type(result.uncertaintyReason) == "string" and #result.uncertaintyReason >= 1
        and #result.uncertaintyReason <= 96, "uncertaintyReason must be 1-96 characters")

    return result
end

local function validateReport(report, options, now)
    if type(report) ~= "table" then
        return false, "InvalidReport"
    end
    if not isFiniteNumber(report.timestamp) or not isFiniteNumber(report.sourceTimestamp)
        or not isFiniteNumber(report.sourceAge) then
        return false, "InvalidReportTimestamp"
    end
    -- [C] Added required checks for expectedSectorCount, blockedSectorCount, and unverifiedConnectionSectorCount
    if type(report.surfaces) ~= "table" or type(report.connections) ~= "table"
        or not isFiniteNumber(report.surfaceCount) or not isFiniteNumber(report.connectionCount)
        or not isFiniteNumber(report.unobservedSectorCount)
        or not isFiniteNumber(report.expectedSectorCount)
        or not isFiniteNumber(report.blockedSectorCount)
        or not isFiniteNumber(report.unverifiedConnectionSectorCount) then
        return false, "InvalidReportShape"
    end
    if report.surfaceCount < 0 or report.surfaceCount > options.maxSurfaces
        or report.surfaceCount % 1 ~= 0 or #report.surfaces ~= report.surfaceCount then
        return false, "SurfaceLimitExceeded"
    end
    if report.connectionCount < 0 or report.connectionCount > options.maxConnections
        or report.connectionCount % 1 ~= 0 or #report.connections ~= report.connectionCount then
        return false, "ConnectionLimitExceeded"
    end
    if report.unobservedSectorCount < 0
        or report.unobservedSectorCount > options.maxUnobservedSectors
        or report.unobservedSectorCount % 1 ~= 0 then
        return false, "InvalidCoverageCount"
    end

    -- [C] Added structural validation logic for sector counts
    if report.expectedSectorCount < 4 or report.expectedSectorCount > 16 or report.expectedSectorCount % 1 ~= 0 then
        return false, "InvalidExpectedSectorCount"
    end
    if report.blockedSectorCount < 0 or report.blockedSectorCount > report.expectedSectorCount or report.blockedSectorCount % 1 ~= 0 then
        return false, "InvalidBlockedSectorCount"
    end
    if report.unverifiedConnectionSectorCount < 0 or report.unverifiedConnectionSectorCount > report.expectedSectorCount or report.unverifiedConnectionSectorCount % 1 ~= 0 then
        return false, "InvalidUnverifiedSectorCount"
    end
    if report.unobservedSectorCount > report.expectedSectorCount then
        return false, "InvalidCoverageCount"
    end

    local age = now - report.timestamp
    if not isFiniteNumber(age) or age < 0 then
        return false, "InvalidTimestamp"
    end
    if age > options.maxReportAge then
        return false, "StaleReport"
    end

    local surfaceIds = {}
    for index, surface in ipairs(report.surfaces) do
        if index > options.maxSurfaces or type(surface) ~= "table"
            or type(surface.id) ~= "string" or #surface.id < 1 or #surface.id > 32
            or not isFiniteVector3(surface.position) then
            return false, "InvalidSurfaceRecord"
        end
        if surfaceIds[surface.id] then
            return false, "DuplicateSurfaceId"
        end
        surfaceIds[surface.id] = true
    end

    for index, connection in ipairs(report.connections) do
        if index > options.maxConnections or type(connection) ~= "table"
            or not surfaceIds[connection.from] or not surfaceIds[connection.to]
            or type(connection.relation) ~= "string"
            or not isFiniteNumber(connection.horizontalGap)
            or not isFiniteNumber(connection.verticalDelta) then
            return false, "InvalidConnectionRecord"
        end
    end

    return true, age
end

function SpatialConfidenceIntegrator.new(options)
    return setmetatable({
        _options = validateOptions(options),
        _destroyed = false,
        _integrationCount = 0,
    }, SpatialConfidenceIntegrator)
end

-- Integrate one L2 report. `stores` may contain:
--   uncertaintyMap = Foundation K UncertaintyMap instance
--   confidenceLedger = Foundation K ConfidenceLedger instance
--   decisionLedger = Foundation K DecisionLedger instance
-- Store writes occur only when the corresponding constructor option is true.
function SpatialConfidenceIntegrator:Integrate(report, stores, now)
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

    local valid, ageOrReason = validateReport(report, self._options, currentTime)
    if not valid then
        return nil, ageOrReason
    end
    local reportAge = ageOrReason
    local options = self._options

    local ageUncertainty = clamp01(reportAge / options.maxReportAge)
    
    -- [D] Replaced coverageUncertainty calculation using report metrics and expectedSectorCount
    local coverageUncertainty = clamp01(
        (report.unobservedSectorCount + report.unverifiedConnectionSectorCount) / report.expectedSectorCount
    )

    local overallUncertainty = clamp01(
        ageUncertainty * options.ageWeight
        + coverageUncertainty * options.coverageWeight
    )
    if report.surfaceCount == 0 then
        overallUncertainty = 1
    end

    local surfaceResults = {}
    local uncertaintyWrites = 0
    local evidenceWrites = 0
    local uncertaintyMap = stores.uncertaintyMap
    local confidenceLedger = stores.confidenceLedger
    local decisionLedger = stores.decisionLedger

    for _, surface in ipairs(report.surfaces) do
        local surfaceUncertainty = overallUncertainty
        local mapStatus = "NotRequested"
        local evidenceStatus = "NotRequested"

        if uncertaintyMap then
            local success, status = uncertaintyMap:Observe(
                surface.position,
                surfaceUncertainty,
                options.uncertaintyReason,
                currentTime
            )
            mapStatus = status
            if success then
                uncertaintyWrites += 1
            end
        end

        if options.recordEvidence and confidenceLedger then
            -- This is evidence that a geometry sample was observed, not evidence
            -- that any route or jump is reachable.
            local quality = clamp01(1 - surfaceUncertainty)
            local success, status = confidenceLedger:Record(
                "SpatialGeometry",
                "GeometryObservation",
                "Supports",
                quality,
                currentTime,
                "L2 surface observed"
            )
            evidenceStatus = status
            if success then
                evidenceWrites += 1
            end
        elseif options.recordEvidence then
            evidenceStatus = "StoreMissing"
        end

        surfaceResults[#surfaceResults + 1] = {
            surfaceId = surface.id,
            position = surface.position,
            uncertainty = surfaceUncertainty,
            uncertaintyMapStatus = mapStatus,
            evidenceStatus = evidenceStatus,
        }
    end

    local decisionStatus = "NotRequested"
    if options.recordDecision then
        if decisionLedger then
            local chosenOption = report.connectionCount > 0
                and "CandidateConnectionsObserved"
                or "NoCandidateConnectionsObserved"
            local reason = report.connectionCount > 0
                and "L2 emitted geometric candidates; movement feasibility remains unverified."
                or "No candidate links were emitted; missing observations do not prove blockage."
            local success, status = decisionLedger:Record({
                decisionType = "AnalysisSummary",
                chosenOption = chosenOption,
                reason = reason,
                alternatives = { "InsufficientEvidence", "FurtherSamplingRequired" },
                evidenceKeys = { "SpatialGeometry" },
                confidenceScore = math.floor((1 - overallUncertainty) * 100 + 0.5),
                uncertainty = overallUncertainty,
                timestamp = currentTime,
            })
            decisionStatus = status
            if not success then
                decisionStatus = status
            end
        else
            decisionStatus = "StoreMissing"
        end
    end

    self._integrationCount += 1
    return {
        status = "Integrated",
        timestamp = currentTime,
        sourceTimestamp = report.timestamp,
        sourceAge = reportAge,
        overallUncertainty = overallUncertainty,
        ageUncertainty = ageUncertainty,
        coverageUncertainty = coverageUncertainty,
        surfaceResults = surfaceResults,
        surfaceCount = #surfaceResults,
        connectionCount = report.connectionCount,
        uncertaintyWrites = uncertaintyWrites,
        evidenceWrites = evidenceWrites,
        decisionStatus = decisionStatus,
        integrationNumber = self._integrationCount,
        interpretation = {
            confidenceIsProbability = false,
            routeReachabilityIsGuaranteed = false,
            missingObservationMeansBlocked = false,
            writesAreSessionOnly = true,
        },
    }, "Integrated"
end

function SpatialConfidenceIntegrator:GetIntegrationCount()
    return self._integrationCount
end

function SpatialConfidenceIntegrator:Destroy()
    self._destroyed = true
end

return SpatialConfidenceIntegrator
