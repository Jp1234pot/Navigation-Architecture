-- Navigation Architecture v2.2
-- Module: BehaviorCoordinator
-- Behavior layer: orchestration of analysis, decisions, destinations,
-- and route requests.
--
-- Responsibilities:
--   - Build local records via LocalRecordProvider.
--   - Request multi-threat analysis from Foundation J.
--   - Pass analysis packets to BehaviorDecision.
--   - Route Pursue proposals through BehaviorRouteCoordinator.
--   - Evaluate Escape destinations before requesting a route.
--   - Preserve provisional-analysis limitations.
--   - Forward path results and progress updates.
--
-- This module does NOT:
--   - Discover targets or classify factions.
--   - Generate arena destination candidates.
--   - Assume incomplete analysis is complete.
--   - Own or destroy injected dependencies.
--   - Implement traversal techniques.
--   - Access server remotes or server-only data.

local BehaviorCoordinator = {}
BehaviorCoordinator.__index = BehaviorCoordinator

local function hasMethods(value, methods)
    if type(value) ~= "table" then
        return false
    end

    for _, methodName in ipairs(methods) do
        local ok, method = pcall(function()
            return value[methodName]
        end)

        if not ok or type(method) ~= "function" then
            return false
        end
    end

    return true
end

local function copyRecord(source)
    if type(source) ~= "table" then
        return source
    end

    local result = {}

    for key, value in pairs(source) do
        if type(value) == "table" then
            result[key] = copyRecord(value)
        else
            result[key] = value
        end
    end

    return result
end

function BehaviorCoordinator.new(config, dependencies, options)
    assert(type(config) == "table",
        "BehaviorCoordinator requires config")

    assert(type(dependencies) == "table",
        "BehaviorCoordinator requires dependencies")

    assert(
        hasMethods(dependencies.localRecordProvider, {
            "BuildLocalRecord",
            "GetLatest",
            "Reset",
        }),
        "A compatible LocalRecordProvider is required"
    )

    assert(
        hasMethods(dependencies.multiThreatAnalysis, {
            "Analyze",
        }),
        "A compatible MultiThreatAnalysis is required"
    )

    assert(
        hasMethods(dependencies.behaviorDecision, {
            "Evaluate", "SetMode", "GetLatest", "Reset",
        }),
        "A compatible BehaviorDecision is required"
    )

    assert(
        hasMethods(dependencies.escapeDestinationEvaluator, {
            "Evaluate", "GetLatest", "Reset",
        }),
        "A compatible EscapeDestinationEvaluator is required"
    )

    assert(
        hasMethods(dependencies.routeCoordinator, {
            "RequestRoute",
            "AcceptPathResult",
            "UpdateProgress",
            "Cancel",
            "GetStatus",
        }),
        "A compatible BehaviorRouteCoordinator is required"
    )

    options = options or {}

    assert(type(options) == "table",
        "BehaviorCoordinator options must be a table")

    local allowProvisionalEscapeRoute =
        options.allowProvisionalEscapeRoute

    if allowProvisionalEscapeRoute == nil then
        allowProvisionalEscapeRoute = false
    end

    assert(
        type(allowProvisionalEscapeRoute) == "boolean",
        "allowProvisionalEscapeRoute must be a boolean"
    )

    return setmetatable({
        Config = config,

        LocalRecordProvider =
            dependencies.localRecordProvider,

        MultiThreatAnalysis =
            dependencies.multiThreatAnalysis,

        BehaviorDecision =
            dependencies.behaviorDecision,

        EscapeDestinationEvaluator =
            dependencies.escapeDestinationEvaluator,

        RouteCoordinator =
            dependencies.routeCoordinator,

        _allowProvisionalEscapeRoute =
            allowProvisionalEscapeRoute,

        _latest = nil,
        _destroyed = false,
    }, BehaviorCoordinator)
end

function BehaviorCoordinator:SetMode(mode)
    if self._destroyed then
        return false, "Destroyed"
    end

    return self.BehaviorDecision:SetMode(mode)
end

function BehaviorCoordinator:GetLatest()
    if self._destroyed then
        return nil, "Destroyed"
    end

    if not self._latest then
        return nil, "NoCoordinationResult"
    end

    return copyRecord(self._latest), "OK"
end

function BehaviorCoordinator:GetStatus()
    if self._destroyed then
        return {
            status = "Destroyed",
            reason = "Destroyed",
        }
    end

    local routeStatus = self.RouteCoordinator:GetStatus()

    return {
        status = "Ready",
        reason = "CoordinationAvailable",
        route = routeStatus,
        timestamp = os.clock(),
    }
end

function BehaviorCoordinator:Process(
    escapeCandidates,
    escapeCandidateProvider
)
    if self._destroyed then
        return nil, "Destroyed"
    end

    if self.Config.enabled ~= true then
        return nil, "NavigationDisabled"
    end

    if self.Config.multiThreatAnalysisEnabled ~= true then
        return nil, "ThreatAnalysisDisabled"
    end

    -- Stage 1: build a fresh local observation record.
    local recordOk, localRecord, recordReason = pcall(function()
        return self.LocalRecordProvider:BuildLocalRecord()
    end)

    if not recordOk then
        return nil, "LocalRecordError:" .. tostring(localRecord)
    end

    if type(localRecord) ~= "table" then
        return nil, recordReason or "LocalRecordUnavailable"
    end

    -- Stage 2: obtain the current multi-threat analysis packet.
    local analysisOk, analysisPacket, analysisReason = pcall(function()
        return self.MultiThreatAnalysis:Analyze(localRecord)
    end)

    if not analysisOk then
        return nil, "ThreatAnalysisError:" .. tostring(analysisPacket)
    end

    if type(analysisPacket) ~= "table" then
        return nil, analysisReason or "AnalysisUnavailable"
    end

    -- Stage 3: convert analysis into a behavior proposal.
    local decisionOk, decision, decisionReason = pcall(function()
        return self.BehaviorDecision:Evaluate(analysisPacket)
    end)

    if not decisionOk then
        return nil, "DecisionEvaluationError:" .. tostring(decision)
    end

    if type(decision) ~= "table" then
        return nil, decisionReason or "DecisionUnavailable"
    end

    local result = {
        status = "DecisionProduced",
        reason = decision.reason,

        mode = decision.mode,
        decision = decision,

        analysisTimestamp = analysisPacket.timestamp,
        partialAnalysis = decision.partialAnalysis == true,

        routeRequested = false,
        routeRequestId = nil,

        escapeEvaluation = nil,

        timestamp = os.clock(),
    }

    -- No route should be requested without a valid proposal.
    if decision.status ~= "ProposalReady"
        or decision.requiresRouteEvaluation ~= true then

        result.status = "NoRouteProposal"
        self._latest = result

        return copyRecord(result), decision.reason
    end

    -- Stage 4A: Escape requires destination evaluation.
    -- Candidate generation is deferred until a fresh threat decision
    -- has produced a valid Escape proposal.
    if decision.mode == "Escape" then
        local resolvedEscapeCandidates = escapeCandidates

        if escapeCandidateProvider ~= nil then
            if type(escapeCandidateProvider) ~= "function" then
                result.status = "ArenaCandidateBuildFailed"
                result.reason = "InvalidCandidateProvider"

                self._latest = result
                return copyRecord(result), result.reason
            end

            local candidateOk, candidates, candidateStatus, candidatePacket =
                pcall(escapeCandidateProvider)

            if not candidateOk then
                result.status = "ArenaCandidateBuildFailed"
                result.reason = tostring(candidates)

                self._latest = result
                return copyRecord(result), result.reason
            end

            if type(candidates) ~= "table" then
                result.status = "ArenaCandidateBuildFailed"
                result.reason = candidateStatus or "NoEscapeCandidates"

                self._latest = result
                return copyRecord(result), result.reason
            end

            resolvedEscapeCandidates = candidates
        end

        local evaluationOk, evaluation, evaluationReason =
            pcall(function()
                return self.EscapeDestinationEvaluator:Evaluate(
                    decision,
                    resolvedEscapeCandidates
                )
            end)

        if not evaluationOk then
            result.status = "DestinationEvaluationError"
            result.reason = tostring(evaluation)

            self._latest = result

            return copyRecord(result), result.reason
        end

        if type(evaluation) ~= "table" then
            result.status = "DestinationUnavailable"
            result.reason =
                evaluationReason or "NoEscapeDestination"

            self._latest = result

            return copyRecord(result), result.reason
        end

        result.escapeEvaluation = evaluation

        -- Incomplete threat analysis does not automatically authorize
        -- an escape route. Provisional routing requires explicit approval.
        if evaluation.status == "ProvisionalDestination"
            and not self._allowProvisionalEscapeRoute then

            result.status = "ProvisionalRouteBlocked"
            result.reason = "ProvisionalEscapeRequiresApproval"

            self._latest = result

            return copyRecord(result), result.reason
        end

        if evaluation.status ~= "DestinationEvaluated"
            and evaluation.status ~= "ProvisionalDestination" then

            result.status = "InvalidDestinationEvaluation"
            result.reason = "UnsupportedEvaluationStatus"

            self._latest = result

            return copyRecord(result), result.reason
        end

        -- Stage 5: submit the selected Escape destination.
        local accepted, requestId, routeReason =
            self.RouteCoordinator:RequestRoute(
                decision,
                evaluation.destination
            )

        result.routeRequested = accepted == true
        result.routeRequestId = requestId

        if accepted then
            result.status = "RouteRequested"
            result.reason = routeReason or "OK"
        else
            result.status = "RouteRequestRejected"
            result.reason = routeReason or "UnknownRouteError"
        end

        self._latest = result

        return copyRecord(result), result.reason
    end

    -- Stage 4B: Pursue uses the priority candidate already selected
    -- and validated by BehaviorDecision.
    if decision.mode == "Pursue" then
        local accepted, requestId, routeReason =
            self.RouteCoordinator:RequestRoute(decision)

        result.routeRequested = accepted == true
        result.routeRequestId = requestId

        if accepted then
            result.status = "RouteRequested"
            result.reason = routeReason or "OK"
        else
            result.status = "RouteRequestRejected"
            result.reason = routeReason or "UnknownRouteError"
        end

        self._latest = result

        return copyRecord(result), result.reason
    end

    result.status = "UnsupportedBehaviorMode"
    result.reason = "UnsupportedBehaviorMode"

    self._latest = result

    return copyRecord(result), result.reason
end

-- The owner of PathfindingEngine must forward its SetOnResult
-- packets here. This coordinator does not replace existing callbacks.
function BehaviorCoordinator:AcceptPathResult(packet)
    if self._destroyed then
        return false, "Destroyed"
    end

    return self.RouteCoordinator:AcceptPathResult(packet)
end

function BehaviorCoordinator:UpdateProgress()
    if self._destroyed then
        return nil, "Destroyed"
    end

    return self.RouteCoordinator:UpdateProgress()
end

function BehaviorCoordinator:Cancel(reason)
    if self._destroyed then
        return false, "Destroyed"
    end

    return self.RouteCoordinator:Cancel(reason)
end

function BehaviorCoordinator:Reset()
    if self._destroyed then
        return false, "Destroyed"
    end

    self._latest = nil

    self.LocalRecordProvider:Reset()
    self.BehaviorDecision:Reset()
    self.EscapeDestinationEvaluator:Reset()

    return true, "Reset"
end

function BehaviorCoordinator:Destroy()
    if self._destroyed then
        return
    end

    -- Dependencies are injected and remain caller-owned.
    self._latest = nil

    self.Config = nil
    self.LocalRecordProvider = nil
    self.MultiThreatAnalysis = nil
    self.BehaviorDecision = nil
    self.EscapeDestinationEvaluator = nil
    self.RouteCoordinator = nil

    self._destroyed = true
end

return BehaviorCoordinator
