-- Navigation Architecture v2.2
-- Module: BehaviorComposition
-- Explicit composition root for Behavior + Arena Analysis.
--
-- This module:
--   - Constructs and owns the Behavior modules it creates.
--   - Constructs and owns ArenaAnalysisPipeline and its adapter.
--   - Injects existing Foundation modules without taking ownership.
--   - Connects PathfindingEngine results to BehaviorCoordinator.
--   - Provides explicit ProcessOnce and UpdateProgress calls.
--
-- This module does NOT:
--   - Create background loops or automatic scan schedules.
--   - Create or modify server scripts.
--   - Access RemoteEvents or RemoteFunctions.
--   - Guarantee physical reachability or escape safety.
--   - Construct or replace NavigationCore.

local MultiThreatAnalysis = require(
	script.Parent.Parent.Foundations.J.MultiThreatAnalysis
)

local LocalRecordProvider = require(
	script.Parent.LocalRecordProvider
)

local BehaviorDecision = require(
	script.Parent.BehaviorDecision
)

local EscapeDestinationEvaluator = require(
	script.Parent.EscapeDestinationEvaluator
)

local BehaviorRouteCoordinator = require(
	script.Parent.BehaviorRouteCoordinator
)

local BehaviorCoordinator = require(
	script.Parent.BehaviorCoordinator
)

local ArenaAnalysisPipeline = require(
	script.Parent.Parent.ArenaAnalysis.ArenaAnalysisPipeline
)

local ArenaEscapeCandidateAdapter = require(
	script.Parent.ArenaEscapeCandidateAdapter
)

local BehaviorComposition = {}
BehaviorComposition.__index = BehaviorComposition

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

local function safeDestroy(value)
	if type(value) ~= "table"
		or type(value.Destroy) ~= "function" then
		return
	end

	pcall(function()
		value:Destroy()
	end)
end

local function destroyOwned(owned)
	for index = #owned, 1, -1 do
		safeDestroy(owned[index])
	end

	table.clear(owned)
end

local function validateDependencies(dependencies)
	assert(type(dependencies) == "table",
		"BehaviorComposition requires dependencies")

	assert(
		hasMethods(dependencies.characterManager, {
			"GetCharacter",
			"GetRoot",
			"IsAlive",
		}),
		"A compatible CharacterManager is required"
	)

	assert(
		hasMethods(dependencies.targetDiscovery, {
			"GetCandidates",
			"IsCandidateCurrent",
		}),
		"A compatible TargetDiscovery is required"
	)

	assert(
		hasMethods(dependencies.physicsObserver, {
			"Observe",
			"ObservePosition",
		}),
		"A compatible PhysicsObserver is required"
	)

	assert(
		hasMethods(dependencies.velocityEstimator, {
			"Update",
			"GetEstimate",
			"Reset",
		}),
		"A compatible VelocityEstimator is required"
	)

	assert(
		hasMethods(dependencies.pathfindingEngine, {
			"RequestPath",
			"Cancel",
			"SetOnResult",
			"GetOnResult",
		}),
		"A compatible PathfindingEngine is required"
	)

	assert(
		hasMethods(dependencies.waypointTracker, {
			"SetPath",
			"Update",
			"GetProgress",
			"Reset",
		}),
		"A compatible WaypointTracker is required"
	)

	local movementController =
		dependencies.movementController

	assert(
		movementController == nil
			or hasMethods(movementController, {
				"SetOnStatus",
				"Start",
				"Stop",
				"GetStatus",
			}),
		"movementController must be compatible or nil"
	)
end

function BehaviorComposition.new(
	config,
	worldRoot,
	dependencies,
	options
)
	assert(type(config) == "table",
		"BehaviorComposition requires validated config")

	assert(
		typeof(worldRoot) == "Instance",
		"BehaviorComposition requires a worldRoot Instance"
	)

	validateDependencies(dependencies)

	options = options or {}

	assert(type(options) == "table",
		"BehaviorComposition options must be a table")

	local previousCallbackCallOk, previousCallback, previousCallbackReason =
		pcall(function()
			return dependencies.pathfindingEngine:GetOnResult()
		end)

	if not previousCallbackCallOk then
		error(
			"Could not read previous PathfindingEngine callback: "
				.. tostring(previousCallback),
			2
		)
	end

	if previousCallbackReason ~= "OK" then
		error(
			"Could not read previous PathfindingEngine callback: "
				.. tostring(previousCallbackReason),
			2
		)
	end

	assert(
		previousCallback == nil
			or type(previousCallback) == "function",
		"PathfindingEngine returned an invalid previous callback"
	)

	local owned = {}

	local function construct(factory)
		local ok, instance = pcall(factory)

		if not ok then
			destroyOwned(owned)
			error(instance, 2)
		end

		if type(instance) ~= "table" then
			destroyOwned(owned)
			error(
				"A composed module returned an invalid instance",
				2
			)
		end

		owned[#owned + 1] = instance

		return instance
	end

	local arenaPipeline = construct(function()
		return ArenaAnalysisPipeline.new(
			worldRoot,
			options.arenaOverrides
		)
	end)

	local arenaAdapter = construct(function()
		return ArenaEscapeCandidateAdapter.new({
			arenaAnalysisPipeline = arenaPipeline,
			characterManager = dependencies.characterManager,
		}, options.adapterOptions)
	end)

	local localRecordProvider = construct(function()
		return LocalRecordProvider.new({
			characterManager = dependencies.characterManager,
			physicsObserver = dependencies.physicsObserver,
			velocityEstimator = dependencies.velocityEstimator,
		})
	end)

	local multiThreatAnalysis = construct(function()
		return MultiThreatAnalysis.new({
			config = config,
			targetDiscovery = dependencies.targetDiscovery,
			physicsObserver = dependencies.physicsObserver,
			velocityEstimator = dependencies.velocityEstimator,
			recoveryAnalysis = dependencies.recoveryAnalysis,
		})
	end)

	local behaviorDecision = construct(function()
		return BehaviorDecision.new(
			config,
			options.decisionOptions
		)
	end)

	local escapeEvaluator = construct(function()
		return EscapeDestinationEvaluator.new(
			config,
			{
				characterManager = dependencies.characterManager,
			},
			options.evaluatorOptions
		)
	end)

	local routeCoordinator = construct(function()
		return BehaviorRouteCoordinator.new(
			config,
			{
				pathfindingEngine = dependencies.pathfindingEngine,
				waypointTracker = dependencies.waypointTracker,
				characterManager = dependencies.characterManager,
				movementController = dependencies.movementController,
			},
			options.routeOptions
		)
	end)

	local behaviorCoordinator = construct(function()
		return BehaviorCoordinator.new(
			config,
			{
				localRecordProvider = localRecordProvider,
				multiThreatAnalysis = multiThreatAnalysis,
				behaviorDecision = behaviorDecision,
				escapeDestinationEvaluator = escapeEvaluator,
				routeCoordinator = routeCoordinator,
			},
			options.behaviorOptions
		)
	end)

	local self = setmetatable({
		Config = config,

		ArenaAnalysisPipeline = arenaPipeline,
		ArenaEscapeCandidateAdapter = arenaAdapter,

		LocalRecordProvider = localRecordProvider,
		MultiThreatAnalysis = multiThreatAnalysis,
		BehaviorDecision = behaviorDecision,
		EscapeDestinationEvaluator = escapeEvaluator,
		BehaviorRouteCoordinator = routeCoordinator,
		BehaviorCoordinator = behaviorCoordinator,

		PathfindingEngine = dependencies.pathfindingEngine,

		_owned = owned,
		_stores = options.stores,
		_previousPathResultCallback = previousCallback,
		_pathResultCallback = nil,

		_destroyed = false,
	}, BehaviorComposition)

	-- The composition layer owns the PathfindingEngine result callback
	-- slot while this composition instance is active.
	local resultCallback = function(packet)
		if self._destroyed then
			return
		end

		-- Isolate BehaviorCoordinator failure from the previous callback.
		local behaviorOk, behaviorError = pcall(function()
			self.BehaviorCoordinator:AcceptPathResult(packet)
		end)

		if not behaviorOk then
			warn(
				"[Navigation v2.2] Behavior path-result callback failed: "
					.. tostring(behaviorError)
			)
		end

		-- The previous owner must still receive the packet independently.
		if self._previousPathResultCallback then
			local previousOk, previousError = pcall(
				self._previousPathResultCallback,
				packet
			)

			if not previousOk then
				warn(
					"[Navigation v2.2] Previous path-result callback failed: "
						.. tostring(previousError)
				)
			end
		end
	end

	local callbackCallOk, callbackAccepted, callbackReason =
		pcall(function()
			return dependencies.pathfindingEngine:SetOnResult(
				resultCallback
			)
		end)

	if not callbackCallOk then
		destroyOwned(owned)

		error(
			"Could not connect PathfindingEngine results: "
				.. tostring(callbackAccepted),
			2
		)
	end

	if not callbackAccepted then
		destroyOwned(owned)

		error(
			"Could not connect PathfindingEngine results: "
				.. tostring(callbackReason),
			2
		)
	end

	self._pathResultCallback = resultCallback

	return self
end

function BehaviorComposition:SetMode(mode)
	if self._destroyed then
		return false, "Destroyed"
	end

	return self.BehaviorCoordinator:SetMode(mode)
end

function BehaviorComposition:GetMode()
	if self._destroyed then
		return nil, "Destroyed"
	end

	return self.BehaviorDecision:GetMode()
end

function BehaviorComposition:ProcessOnce(
	movementEnvelope,
	stores
)
	if self._destroyed then
		return nil, "Destroyed"
	end

	local mode, modeReason =
		self.BehaviorDecision:GetMode()

	if not mode then
		return nil, modeReason
	end

	local escapeCandidateProvider = nil

	if mode == "Escape" then
		escapeCandidateProvider = function()
			if type(movementEnvelope) ~= "table" then
				return nil, "MovementEnvelopeRequired", nil
			end

			return self.ArenaEscapeCandidateAdapter:BuildCandidates(
				movementEnvelope,
				stores or self._stores
			)
		end
	end

	-- BehaviorCoordinator now evaluates threats first.
	-- The provider is invoked only after a valid Escape proposal.
	return self.BehaviorCoordinator:Process(
		nil,
		escapeCandidateProvider
	)
end

function BehaviorComposition:AcceptPathResult(packet)
	if self._destroyed then
		return false, "Destroyed"
	end

	return self.BehaviorCoordinator:AcceptPathResult(packet)
end

-- Progress is deliberately explicit.
-- The caller decides when to invoke this method.
function BehaviorComposition:UpdateProgress()
	if self._destroyed then
		return nil, "Destroyed"
	end

	return self.BehaviorCoordinator:UpdateProgress()
end

function BehaviorComposition:GetLatest()
	if self._destroyed then
		return nil, "Destroyed"
	end

	return self.BehaviorCoordinator:GetLatest()
end

function BehaviorComposition:GetStatus()
	if self._destroyed then
		return {
			status = "Destroyed",
			reason = "Destroyed",
		}
	end

	local behaviorStatus =
		self.BehaviorCoordinator:GetStatus()

	local arenaCounts =
		self.ArenaAnalysisPipeline:GetCounts()

	return {
		status = "Ready",
		behavior = behaviorStatus,
		arenaAnalysisCounts = arenaCounts,
		timestamp = os.clock(),
	}
end

function BehaviorComposition:Cancel(reason)
	if self._destroyed then
		return false, "Destroyed"
	end

	return self.BehaviorCoordinator:Cancel(reason)
end

function BehaviorComposition:Reset()
	if self._destroyed then
		return false, "Destroyed"
	end

	local behaviorOk, behaviorReason = self.BehaviorCoordinator:Reset()
	if not behaviorOk then
		return false, behaviorReason
	end

	local adapterOk, adapterReason = self.ArenaEscapeCandidateAdapter:Reset()
	if not adapterOk then
		return false, adapterReason
	end

	local pipelineOk, pipelineReason = self.ArenaAnalysisPipeline:ClearLatest()
	if not pipelineOk then
		return false, pipelineReason
	end

	return true, "Reset"
end

function BehaviorComposition:Destroy()
	if self._destroyed then
		return
	end

	self._destroyed = true

	-- Restore the previous callback only while this composition
	-- still owns the PathfindingEngine callback slot.
	if self.PathfindingEngine and self._pathResultCallback then
		local readOk, currentCallback, readReason = pcall(function()
			return self.PathfindingEngine:GetOnResult()
		end)

		if readOk
			and readReason == "OK"
			and currentCallback == self._pathResultCallback then

			pcall(function()
				self.PathfindingEngine:SetOnResult(
					self._previousPathResultCallback
				)
			end)
		end
	end

	-- Reverse construction order:
	-- coordinators first, then their owned dependencies.
	destroyOwned(self._owned)

	self.Config = nil

	self.ArenaAnalysisPipeline = nil
	self.ArenaEscapeCandidateAdapter = nil

	self.LocalRecordProvider = nil
	self.MultiThreatAnalysis = nil
	self.BehaviorDecision = nil
	self.EscapeDestinationEvaluator = nil
	self.BehaviorRouteCoordinator = nil
	self.BehaviorCoordinator = nil

	self.PathfindingEngine = nil

	self._previousPathResultCallback = nil
	self._pathResultCallback = nil
	self._stores = nil
end

return BehaviorComposition
