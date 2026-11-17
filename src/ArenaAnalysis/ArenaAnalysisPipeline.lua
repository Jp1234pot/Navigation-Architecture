-- Navigation Architecture v2.2
-- Unified explicit-call coordinator for Arena Analysis Foundations L1-L5.
-- This module observes and analyzes local geometry only. It never moves a character.

local ArenaGeometryObserver = require(script.Parent.ArenaGeometryObserver)
local ReachabilityAnalyzer = require(script.Parent.ReachabilityAnalyzer)
local SpatialConfidenceIntegrator = require(script.Parent.SpatialConfidenceIntegrator)
local RouteLaboratory = require(script.Parent.RouteLaboratory)
local MovementFeasibilityAnalyzer = require(script.Parent.MovementFeasibilityAnalyzer)
local ArenaAnalysisConfig = require(script.Parent.ArenaAnalysisConfig)

local ArenaAnalysisPipeline = {}
ArenaAnalysisPipeline.__index = ArenaAnalysisPipeline

function ArenaAnalysisPipeline.new(worldRoot, overrides)
    local config = ArenaAnalysisConfig.Create(overrides)

    local self = setmetatable({
        _config = config,
        _destroyed = false,
        _latest = nil,
        _observer = ArenaGeometryObserver.new(worldRoot, config.observer),
        _reachability = ReachabilityAnalyzer.new(config.reachability),
        _confidence = SpatialConfidenceIntegrator.new(config.confidence),
        _routes = RouteLaboratory.new(config.route),
        _feasibility = MovementFeasibilityAnalyzer.new(config.feasibility),
    }, ArenaAnalysisPipeline)

    return self
end

-- Performs one bounded L1 scan, one L2 analysis, and optionally one L3
-- confidence integration. The returned report contains the surface IDs that
-- the caller may inspect before selecting route endpoints for Compare().
-- `stores` is optional caller-owned Foundation K storage; this pipeline never
-- creates or destroys those stores.
function ArenaAnalysisPipeline:Observe(origin, characterToExclude, stores)
    if self._destroyed then
        return nil, "Destroyed"
    end

    -- A failed new observation must not leave an older report available to Compare().
    self._latest = nil

    local snapshot, scanStatus = self._observer:Scan(origin, characterToExclude)
    if not snapshot then
        return nil, { stage = "L1", reason = scanStatus }
    end

    local report, analysisStatus = self._reachability:Analyze(snapshot)
    if not report then
        return nil, { stage = "L2", reason = analysisStatus, snapshot = snapshot }
    end

    local confidence = nil
    local confidenceStatus = "Disabled"
    if self._config.enableSpatialConfidence then
        local integrated, integrationStatus = self._confidence:Integrate(report, stores)
        if integrated then
            confidence = integrated
            confidenceStatus = integrationStatus
        else
            -- L3 is an enhancement, not a prerequisite for L4. Preserve the
            -- valid L1/L2 result and let L4 use its configured default estimate.
            confidenceStatus = integrationStatus
        end
    end

    local packet = {
        snapshot = snapshot,
        report = report,
        confidence = confidence,
        confidenceStatus = confidenceStatus,
        observedAt = os.clock(),
        statuses = {
            geometry = scanStatus,
            reachability = analysisStatus,
            confidence = confidenceStatus,
        },
        limits = {
            performsWorldQueries = true,
            raycastCount = snapshot.rayCount,
            movesCharacter = false,
            selectsTargets = false,
            tracksPlayersOrTools = false,
            tracksBombOrMatchState = false,
        },
    }
    self._latest = packet

    return packet, "Observed"
end

-- Compares candidate routes using the latest successful L2 report. The caller
-- must select startSurfaceId and goalSurfaceId from that report. If an explicit
-- movementEnvelope is supplied, L5 evaluates each returned route against it.
-- `stores` is optional caller-owned Foundation K storage for L4 decision logs.
function ArenaAnalysisPipeline:Compare(startSurfaceId, goalSurfaceId, movementEnvelope, stores)
    if self._destroyed then
        return nil, "Destroyed"
    end
    if not self._latest or not self._latest.report then
        return nil, "ObserveBeforeCompare"
    end

    local comparison, compareStatus = self._routes:Compare(
        self._latest.report,
        startSurfaceId,
        goalSurfaceId,
        self._latest.confidence,
        stores
    )
    if not comparison then
        return nil, { stage = "L4", reason = compareStatus }
    end

    local feasibility = nil
    local feasibilityStatus = "NotRequested"
    if movementEnvelope ~= nil and self._config.enableFeasibility then
        feasibility = {}
        for index, route in ipairs(comparison.routes) do
            local assessment, assessmentStatus = self._feasibility:Analyze(route, movementEnvelope)
            if assessment then
                feasibility[#feasibility + 1] = {
                    routeIndex = index,
                    assessment = assessment,
                    status = assessmentStatus,
                }
            else
                feasibility[#feasibility + 1] = {
                    routeIndex = index,
                    assessment = nil,
                    status = assessmentStatus,
                }
            end
        end
        feasibilityStatus = "Analyzed"
    elseif movementEnvelope ~= nil then
        feasibilityStatus = "Disabled"
    end

    return {
        comparison = comparison,
        feasibility = feasibility,
        confidence = self._latest.confidence,
        statuses = {
            routes = compareStatus,
            feasibility = feasibilityStatus,
            confidence = self._latest.confidenceStatus,
        },
        limits = {
            routesAreHypothetical = true,
            routeSearchIsExhaustive = comparison.isExhaustive == true,
            movementWasExecuted = false,
            physicalReachabilityGuaranteed = false,
            feasibilityIsHeuristic = feasibility ~= nil,
        },
    }, compareStatus
end

function ArenaAnalysisPipeline:GetLatest()
    if self._destroyed then
        return nil, "Destroyed"
    end
    return self._latest
end

function ArenaAnalysisPipeline:ClearLatest()
    if self._destroyed then
        return false, "Destroyed"
    end
    self._latest = nil
    return true, "Cleared"
end

function ArenaAnalysisPipeline:GetCounts()
    if self._destroyed then
        return nil, "Destroyed"
    end
    return {
        scans = self._observer:GetScanCount(),
        reachabilityAnalyses = self._reachability:GetAnalysisCount(),
        confidenceIntegrations = self._confidence:GetIntegrationCount(),
        routeComparisons = self._routes:GetComparisonCount(),
        feasibilityAnalyses = self._feasibility:GetAnalysisCount(),
    }
end

function ArenaAnalysisPipeline:Destroy()
    if self._destroyed then
        return
    end
    self._destroyed = true
    self._latest = nil
    self._observer:Destroy()
    self._reachability:Destroy()
    self._confidence:Destroy()
    self._routes:Destroy()
    self._feasibility:Destroy()
end

return ArenaAnalysisPipeline
