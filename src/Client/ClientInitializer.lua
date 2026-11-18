-- Navigation Architecture v2.2
-- Module: ClientInitializer
-- Client-side construction and lifecycle entry point.
--
-- Constructs Foundations A-K and BehaviorComposition.
-- Injects constructed modules into NavigationCore for validation.
--
-- Does NOT automatically start sampling, process behavior,
-- request paths, or start movement.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local Config = require(script.Parent.Parent.Foundations.A.Config)
local StateManager = require(script.Parent.Parent.Foundations.A.StateManager)
local LifecycleManager = require(script.Parent.Parent.Foundations.A.LifecycleManager)
local CharacterManager = require(script.Parent.Parent.Foundations.A.CharacterManager)

local FactionValidator = require(script.Parent.Parent.Foundations.B.FactionValidator)
local TargetDiscovery = require(script.Parent.Parent.Foundations.B.TargetDiscovery)

local PhysicsObserver = require(script.Parent.Parent.Foundations.C.PhysicsObserver)
local VelocityEstimator = require(script.Parent.Parent.Foundations.C.VelocityEstimator)

local SamplingCoordinator = require(script.Parent.Parent.Foundations.D.SamplingCoordinator)
local TelemetryPanel = require(script.Parent.Parent.Foundations.E.TelemetryPanel)

local PathfindingEngine = require(script.Parent.Parent.Foundations.F.PathfindingEngine)
local WaypointTracker = require(script.Parent.Parent.Foundations.G.WaypointTracker)
local MovementController = require(script.Parent.Parent.Foundations.H.MovementController)

local RecoveryAnalysis = require(script.Parent.Parent.Foundations.I.RecoveryAnalysis)
local AdaptiveRepath = require(script.Parent.Parent.Foundations.I.AdaptiveRepath)

local ConfidenceLedger = require(script.Parent.Parent.Foundations.K.ConfidenceLedger)
local DecisionLedger = require(script.Parent.Parent.Foundations.K.DecisionLedger)
local UncertaintyMap = require(script.Parent.Parent.Foundations.K.UncertaintyMap)

local NavigationCore = require(script.Parent.Parent.Core.NavigationCore)
local BehaviorComposition = require(script.Parent.Parent.Behavior.BehaviorComposition)

local ClientInitializer = {}
ClientInitializer.__index = ClientInitializer

local function safeDestroy(instance)
    if type(instance) ~= "table"
        or type(instance.Destroy) ~= "function" then
        return
    end

    pcall(function()
        instance:Destroy()
    end)
end

local function validateOptions(options)
    assert(type(options) == "table",
        "ClientInitializer options must be a table")

    assert(
        options.configOverrides == nil
            or type(options.configOverrides) == "table",
        "configOverrides must be a table or nil"
    )

    assert(
        options.arenaOverrides == nil
            or type(options.arenaOverrides) == "table",
        "arenaOverrides must be a table or nil"
    )

    return options
end

function ClientInitializer.new(options)
    options = validateOptions(options or {})

    local player = options.player or Players.LocalPlayer
    local worldRoot = options.worldRoot or Workspace

    assert(
        typeof(player) == "Instance" and player:IsA("Player"),
        "ClientInitializer requires LocalPlayer"
    )

    assert(
        typeof(worldRoot) == "Instance",
        "ClientInitializer requires a worldRoot Instance"
    )

    -- Avoid creating a UI unless the caller explicitly enables it.
    local configOverrides = table.clone(
        options.configOverrides or {}
    )

    if configOverrides.telemetryPanelEnabled == nil then
        configOverrides.telemetryPanelEnabled = false
    end

    local config = Config.Create(configOverrides)

    -- LifecycleManager owns the constructed modules.
    -- Cleanup callbacks execute in reverse registration order.
    local lifecycle = LifecycleManager.new()

    local function construct(factory)
        local ok, instance = pcall(factory)

        if not ok then
            lifecycle:Destroy()
            error(instance, 2)
        end

        assert(
            type(instance) == "table",
            "Constructed module must return a table"
        )

        -- Some modules own no resources and have no Destroy method.
        if type(instance.Destroy) == "function" then
            local registered = lifecycle:AddCleanup(function()
                safeDestroy(instance)
            end)

            if not registered then
                safeDestroy(instance)
                lifecycle:Destroy()
                error("Could not register module cleanup", 2)
            end
        end

        return instance
    end

    local ok, result = pcall(function()
        -- FOUNDATION A
        local stateManager = construct(function()
            return StateManager.new()
        end)

        local characterManager = construct(function()
            return CharacterManager.new(player)
        end)

        -- FOUNDATION B
        local factionValidator = construct(function()
            return FactionValidator.new(config)
        end)

        local targetDiscovery = construct(function()
            return TargetDiscovery.new(
                player,
                config,
                factionValidator
            )
        end)

        -- FOUNDATION C
        local physicsObserver = construct(function()
            return PhysicsObserver.new()
        end)

        local velocityEstimator = construct(function()
            return VelocityEstimator.new(config)
        end)

        -- FOUNDATION D
        -- Constructed but NOT started.
        local samplingCoordinator = construct(function()
            return SamplingCoordinator.new({
                config = config,
                player = player,
                characterManager = characterManager,
                targetDiscovery = targetDiscovery,
                physicsObserver = physicsObserver,
                velocityEstimator = velocityEstimator,
                runService = RunService,
            })
        end)

        -- FOUNDATION E
        local telemetryPanel = construct(function()
            return TelemetryPanel.new(
                player,
                config.telemetryPanelEnabled
            )
        end)

        -- FOUNDATION F
        local pathfindingEngine = construct(function()
            return PathfindingEngine.new(config)
        end)

        -- FOUNDATION G
        local waypointTracker = construct(function()
            return WaypointTracker.new(config)
        end)

        -- FOUNDATION H
        local movementController = construct(function()
            return MovementController.new(
                config,
                characterManager
            )
        end)

        -- FOUNDATION I
        local recoveryAnalysis = construct(function()
            return RecoveryAnalysis.new(config)
        end)

        local adaptiveRepath = construct(function()
            return AdaptiveRepath.new(
                config,
                recoveryAnalysis
            )
        end)

        -- FOUNDATION K
        local confidenceLedger = construct(function()
            return ConfidenceLedger.new(config)
        end)

        local decisionLedger = construct(function()
            return DecisionLedger.new(config)
        end)

        local uncertaintyMap = construct(function()
            return UncertaintyMap.new(config)
        end)

        -- Shared stores supplied to Arena Analysis.
        local stores = {
            confidenceLedger = confidenceLedger,
            decisionLedger = decisionLedger,
            uncertaintyMap = uncertaintyMap,
        }

        -- BEHAVIOR + ARENA ANALYSIS
        local behaviorComposition = construct(function()
            return BehaviorComposition.new(
                config,
                worldRoot,
                {
                    characterManager = characterManager,
                    targetDiscovery = targetDiscovery,
                    physicsObserver = physicsObserver,
                    velocityEstimator = velocityEstimator,
                    pathfindingEngine = pathfindingEngine,
                    waypointTracker = waypointTracker,
                    movementController = movementController,
                    recoveryAnalysis = recoveryAnalysis,
                },
                {
                    arenaOverrides = options.arenaOverrides,
                    adapterOptions = options.adapterOptions,
                    decisionOptions = options.decisionOptions,
                    evaluatorOptions = options.evaluatorOptions,
                    routeOptions = options.routeOptions,
                    behaviorOptions = options.behaviorOptions,
                    stores = stores,
                }
            )
        end)

        -- NAVIGATION CORE
        -- Core validates the assembled interfaces.
        -- It does not construct or control these modules.
        local modules = {
            StateManager = stateManager,
            LifecycleManager = lifecycle,
            CharacterManager = characterManager,

            FactionValidator = factionValidator,
            TargetDiscovery = targetDiscovery,

            PhysicsObserver = physicsObserver,
            VelocityEstimator = velocityEstimator,

            SamplingCoordinator = samplingCoordinator,
            TelemetryPanel = telemetryPanel,

            PathfindingEngine = pathfindingEngine,
            WaypointTracker = waypointTracker,
            MovementController = movementController,

            RecoveryAnalysis = recoveryAnalysis,
            AdaptiveRepath = adaptiveRepath,

            MultiThreatAnalysis =
                behaviorComposition.MultiThreatAnalysis,

            LocalRecordProvider =
                behaviorComposition.LocalRecordProvider,

            ConfidenceLedger = confidenceLedger,
            DecisionLedger = decisionLedger,
            UncertaintyMap = uncertaintyMap,

            BehaviorDecision =
                behaviorComposition.BehaviorDecision,

            EscapeDestinationEvaluator =
                behaviorComposition.EscapeDestinationEvaluator,

            BehaviorRouteCoordinator =
                behaviorComposition.BehaviorRouteCoordinator,

            BehaviorCoordinator =
                behaviorComposition.BehaviorCoordinator,
        }

        local navigationCore = construct(function()
            return NavigationCore.new({
                config = config,
                modules = modules,
            })
        end)

        return {
            Config = config,
            Player = player,
            WorldRoot = worldRoot,

            StateManager = stateManager,
            CharacterManager = characterManager,

            FactionValidator = factionValidator,
            TargetDiscovery = targetDiscovery,

            PhysicsObserver = physicsObserver,
            VelocityEstimator = velocityEstimator,

            SamplingCoordinator = samplingCoordinator,
            TelemetryPanel = telemetryPanel,

            PathfindingEngine = pathfindingEngine,
            WaypointTracker = waypointTracker,
            MovementController = movementController,

            RecoveryAnalysis = recoveryAnalysis,
            AdaptiveRepath = adaptiveRepath,

            ConfidenceLedger = confidenceLedger,
            DecisionLedger = decisionLedger,
            UncertaintyMap = uncertaintyMap,

            BehaviorComposition = behaviorComposition,
            NavigationCore = navigationCore,

            Stores = stores,
            Lifecycle = lifecycle,
        }
    end)

    if not ok then
        lifecycle:Destroy()
        error(result, 2)
    end

    return setmetatable({
        _modules = result,
        _destroyed = false,
    }, ClientInitializer)
end

function ClientInitializer:SetMode(mode)
    if self._destroyed then
        return false, "Destroyed"
    end

    return self._modules.BehaviorComposition:SetMode(mode)
end

function ClientInitializer:ProcessOnce(movementEnvelope)
    if self._destroyed then
        return nil, "Destroyed"
    end

    return self._modules.BehaviorComposition:ProcessOnce(
        movementEnvelope,
        self._modules.Stores
    )
end

function ClientInitializer:UpdateProgress()
    if self._destroyed then
        return nil, "Destroyed"
    end

    return self._modules.BehaviorComposition:UpdateProgress()
end

-- Sampling is an explicit opt-in.
function ClientInitializer:StartSampling()
    if self._destroyed then
        return false, "Destroyed"
    end

    return self._modules.SamplingCoordinator:Start()
end

function ClientInitializer:StopSampling()
    if self._destroyed then
        return false, "Destroyed"
    end

    return self._modules.SamplingCoordinator:Stop()
end

function ClientInitializer:SetSamplingTarget(candidate)
    if self._destroyed then
        return false, "Destroyed"
    end

    return self._modules.SamplingCoordinator:SetTarget(candidate)
end

function ClientInitializer:ClearSamplingTarget(reason)
    if self._destroyed then
        return false, "Destroyed"
    end

    return self._modules.SamplingCoordinator:ClearTarget(reason)
end

function ClientInitializer:GetSamplingLatest()
    if self._destroyed then
        return nil, "Destroyed"
    end

    return self._modules.SamplingCoordinator:GetLatest()
end

function ClientInitializer:GetStatus()
    if self._destroyed then
        return {
            status = "Destroyed",
            reason = "Destroyed",
        }
    end

    local modules = self._modules

    return {
        status = modules.NavigationCore:GetStatus(),
        capabilities = modules.NavigationCore:GetCapabilities(),
        errors = modules.NavigationCore:GetErrors(),
        behavior = modules.BehaviorComposition:GetStatus(),
        sampling = modules.SamplingCoordinator:GetLatest(),
        timestamp = os.clock(),
    }
end

function ClientInitializer:GetModule(name)
    if self._destroyed then
        return nil, "Destroyed"
    end

    return self._modules.NavigationCore:GetModule(name)
end

function ClientInitializer:Destroy()
    if self._destroyed then
        return false, "AlreadyDestroyed"
    end

    self._destroyed = true

    local lifecycle = self._modules.Lifecycle
    lifecycle:Destroy()

    table.clear(self._modules)
    self._modules = nil

    return true, "Destroyed"
end

return ClientInitializer
