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

local OPTIONAL_CAPABILITIES = {
    StateManager = {},

    SamplingCoordinator = {
        "CoordinatedSampling",
    },

    TelemetryPanel = {
        "TelemetryPresentation",
    },

    MovementController = {
        "LocalMovement",
    },

    RecoveryAnalysis = {
        "RecoveryAnalysis",
    },

    AdaptiveRepath = {
        "AdaptiveRepath",
    },

    ConfidenceLedger = {
        "ConfidenceAssessment",
    },

    DecisionLedger = {
        "DecisionRecording",
    },

    UncertaintyMap = {
        "UncertaintyTracking",
    },
}

local function safeDestroy(instance)
    if type(instance) ~= "table" then
        return false
    end

    local lookupOk, destroyMethod = pcall(function()
        return instance.Destroy
    end)

    if not lookupOk or type(destroyMethod) ~= "function" then
        return false
    end

    local destroyOk = pcall(destroyMethod, instance)
    return destroyOk
end

local function getCallable(module, methodName)
    if type(module) ~= "table" then
        return nil
    end

    local ok, method = pcall(function()
        return module[methodName]
    end)

    if not ok or type(method) ~= "function" then
        return nil
    end

    return method
end

local function getBehaviorCompositionMethod(self, methodName)
    local modules = self._modules
    local core = modules and modules.NavigationCore

    if type(core) ~= "table" then
        return nil, nil, "CoreUnavailable"
    end

    local composition, moduleReason = core:GetModule("BehaviorComposition")

    if not composition then
        return nil, nil, moduleReason
    end

    local method = getCallable(composition, methodName)

    if not method then
        return nil, nil, "MissingBehaviorCompositionMethod:" .. methodName
    end

    return composition, method, "OK"
end

local function stringifyReason(reason)
    local ok, message = pcall(tostring, reason)

    if ok then
        return message
    end

    return "UnknownError"
end

local function copyInitializationErrors(source)
    local result = {}

    for _, record in ipairs(source or {}) do
        result[#result + 1] = {
            module = record.module,
            stage = record.stage,
            reason = record.reason,
            affectedCapabilities = table.clone(
                record.affectedCapabilities or {}
            ),
        }
    end

    return result
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

    -- Required infrastructure.
    local config = Config.Create(configOverrides)
    local lifecycle = LifecycleManager.new()

    local initializationErrors = {}

    local function recordOptionalFailure(
        moduleName,
        stage,
        reason
    )
        initializationErrors[#initializationErrors + 1] = {
            module = moduleName,
            stage = stage,
            reason = stringifyReason(reason),
            affectedCapabilities = table.clone(
                OPTIONAL_CAPABILITIES[moduleName] or {}
            ),
        }
    end

    -- Every successfully constructed module that owns a Destroy
    -- method is registered with the shared lifecycle manager.
    local function registerCleanup(instance)
        local lookupOk, destroyMethod = pcall(function()
            return instance.Destroy
        end)

        if not lookupOk then
            return false, "DestroyMethodLookupFailed"
        end

        -- Some modules own no external resources.
        if type(destroyMethod) ~= "function" then
            return true, "NoCleanupRequired"
        end

        local registered = lifecycle:AddCleanup(function()
            safeDestroy(instance)
        end)

        if not registered then
            safeDestroy(instance)
            return false, "CleanupRegistrationFailed"
        end

        return true, "Registered"
    end

    -- Required constructors stop initialization on failure.
    local function constructRequired(moduleName, factory)
        local ok, instance = pcall(factory)

        if not ok then
            error(
                string.format(
                    "[%s] ConstructionFailed: %s",
                    moduleName,
                    stringifyReason(instance)
                ),
                2
            )
        end

        if type(instance) ~= "table" then
            error(
                string.format(
                    "[%s] InvalidConstructorResult",
                    moduleName
                ),
                2
            )
        end

        local registered, reason = registerCleanup(instance)

        if not registered then
            error(
                string.format(
                    "[%s] %s",
                    moduleName,
                    tostring(reason)
                ),
                2
            )
        end

        return instance
    end

    -- Optional constructors fail independently.
    local function constructOptional(moduleName, factory)
        local ok, instance = pcall(factory)

        if not ok then
            recordOptionalFailure(
                moduleName,
                "Construction",
                instance
            )
            return nil
        end

        if type(instance) ~= "table" then
            recordOptionalFailure(
                moduleName,
                "Validation",
                "InvalidConstructorResult"
            )
            return nil
        end

        local registered, reason = registerCleanup(instance)

        if not registered then
            recordOptionalFailure(
                moduleName,
                "CleanupRegistration",
                reason
            )
            return nil
        end

        return instance
    end

    local ok, result = pcall(function()
        -- FOUNDATION A
        -- StateManager is optional. CharacterManager is required.
        local stateManager = constructOptional(
            "StateManager",
            function()
                return StateManager.new()
            end
        )

        local characterManager = constructRequired(
            "CharacterManager",
            function()
                return CharacterManager.new(player)
            end
        )

        -- FOUNDATION B
        local factionValidator = constructRequired(
            "FactionValidator",
            function()
                return FactionValidator.new(config)
            end
        )

        local targetDiscovery = constructRequired(
            "TargetDiscovery",
            function()
                return TargetDiscovery.new(
                    player,
                    config,
                    factionValidator
                )
            end
        )

        -- FOUNDATION C
        local physicsObserver = constructRequired(
            "PhysicsObserver",
            function()
                return PhysicsObserver.new()
            end
        )

        local velocityEstimator = constructRequired(
            "VelocityEstimator",
            function()
                return VelocityEstimator.new(config)
            end
        )

        -- FOUNDATION D
        -- Optional. Constructed but NOT started.
        local samplingCoordinator = constructOptional(
            "SamplingCoordinator",
            function()
                return SamplingCoordinator.new({
                    config = config,
                    player = player,
                    characterManager = characterManager,
                    targetDiscovery = targetDiscovery,
                    physicsObserver = physicsObserver,
                    velocityEstimator = velocityEstimator,
                    runService = RunService,
                })
            end
        )

        -- FOUNDATION E
        local telemetryPanel = constructOptional(
            "TelemetryPanel",
            function()
                return TelemetryPanel.new(
                    player,
                    config.telemetryPanelEnabled
                )
            end
        )

        -- FOUNDATION F
        local pathfindingEngine = constructRequired(
            "PathfindingEngine",
            function()
                return PathfindingEngine.new(config)
            end
        )

        -- FOUNDATION G
        local waypointTracker = constructRequired(
            "WaypointTracker",
            function()
                return WaypointTracker.new(config)
            end
        )

        -- FOUNDATION H
        -- MovementController is optional to BehaviorComposition.
        local movementController = constructOptional(
            "MovementController",
            function()
                return MovementController.new(
                    config,
                    characterManager
                )
            end
        )

        -- FOUNDATION I
        local recoveryAnalysis = constructOptional(
            "RecoveryAnalysis",
            function()
                return RecoveryAnalysis.new(config)
            end
        )

        -- AdaptiveRepath accepts nil RecoveryAnalysis.
        -- It remains independently constructible if that module fails.
        local adaptiveRepath = constructOptional(
            "AdaptiveRepath",
            function()
                return AdaptiveRepath.new(
                    config,
                    recoveryAnalysis
                )
            end
        )

        -- FOUNDATION K
        local confidenceLedger = constructOptional(
            "ConfidenceLedger",
            function()
                return ConfidenceLedger.new(config)
            end
        )

        local decisionLedger = constructOptional(
            "DecisionLedger",
            function()
                return DecisionLedger.new(config)
            end
        )

        local uncertaintyMap = constructOptional(
            "UncertaintyMap",
            function()
                return UncertaintyMap.new(config)
            end
        )

        -- Shared stores supplied to Arena Analysis.
        -- Missing optional stores remain absent from this table.
        local stores = {
            confidenceLedger = confidenceLedger,
            decisionLedger = decisionLedger,
            uncertaintyMap = uncertaintyMap,
        }

        -- BEHAVIOR + ARENA ANALYSIS
        -- This is a required behavior bundle.
        -- Its internal dependencies are not independently isolated here.
        local behaviorComposition = constructRequired(
            "BehaviorComposition",
            function()
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
            end
        )

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

            BehaviorComposition = behaviorComposition,
        }

        local navigationCore = constructRequired(
            "NavigationCore",
            function()
                return NavigationCore.new({
                    config = config,
                    modules = modules,
                })
            end
        )

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

            InitializationErrors = initializationErrors,
        }
    end)

    if not ok then
        -- Required construction failed.
        -- LifecycleManager cleans every previously registered module.
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

    local composition, method, reason = getBehaviorCompositionMethod(self, "SetMode")

    if not method then
        return false, reason
    end

    return method(composition, mode)
end

function ClientInitializer:ProcessOnce(movementEnvelope)
    if self._destroyed then
        return nil, "Destroyed"
    end

    local composition, method, reason = getBehaviorCompositionMethod(self, "ProcessOnce")

    if not method then
        return nil, reason
    end

    return method(
        composition,
        movementEnvelope,
        self._modules.Stores
    )
end

function ClientInitializer:UpdateProgress()
    if self._destroyed then
        return nil, "Destroyed"
    end

    local composition, method, reason = getBehaviorCompositionMethod(self, "UpdateProgress")

    if not method then
        return nil, reason
    end

    return method(composition)
end

-- Sampling is an explicit opt-in.
function ClientInitializer:StartSampling()
    if self._destroyed then
        return false, "Destroyed"
    end

    local module = self._modules.NavigationCore:GetModule(
        "SamplingCoordinator"
    )
    local method = getCallable(module, "Start")

    if not method then
        return false, "ModuleUnavailable"
    end

    return method(module)
end

function ClientInitializer:StopSampling()
    if self._destroyed then
        return false, "Destroyed"
    end

    local module = self._modules.NavigationCore:GetModule(
        "SamplingCoordinator"
    )
    local method = getCallable(module, "Stop")

    if not method then
        return false, "ModuleUnavailable"
    end

    return method(module)
end

function ClientInitializer:SetSamplingTarget(candidate)
    if self._destroyed then
        return false, "Destroyed"
    end

    local module = self._modules.NavigationCore:GetModule(
        "SamplingCoordinator"
    )
    local method = getCallable(module, "SetTarget")

    if not method then
        return false, "ModuleUnavailable"
    end

    return method(module, candidate)
end

function ClientInitializer:ClearSamplingTarget(reason)
    if self._destroyed then
        return false, "Destroyed"
    end

    local module = self._modules.NavigationCore:GetModule(
        "SamplingCoordinator"
    )
    local method = getCallable(module, "ClearTarget")

    if not method then
        return false, "ModuleUnavailable"
    end

    return method(module, reason)
end

function ClientInitializer:GetSamplingLatest()
    if self._destroyed then
        return nil, "Destroyed"
    end

    local module = self._modules.NavigationCore:GetModule(
        "SamplingCoordinator"
    )
    local method = getCallable(module, "GetLatest")

    if not method then
        return nil, "ModuleUnavailable"
    end

    return method(module)
end

function ClientInitializer:GetStatus()
    if self._destroyed then
        return {
            status = "Destroyed",
            reason = "Destroyed",
        }
    end

    local modules = self._modules
    local navigationCore = modules.NavigationCore

    local coreStatus = navigationCore:GetStatus()
    local coreErrors = navigationCore:GetErrors()
    local initializationErrors = copyInitializationErrors(
        modules.InitializationErrors
    )

    local combinedErrors = {}

    for _, record in ipairs(coreErrors) do
        combinedErrors[#combinedErrors + 1] = record
    end

    for _, record in ipairs(initializationErrors) do
        combinedErrors[#combinedErrors + 1] = record
    end

    local sampling = nil
    local samplingStatus = "ModuleUnavailable"
    local samplingError = nil

    local samplingModule = navigationCore:GetModule("SamplingCoordinator")
    local getLatest = getCallable(
        samplingModule,
        "GetLatest"
    )

    if getLatest then
        local ok, latest, reason = pcall(
            getLatest,
            samplingModule
        )

        if ok then
            sampling = latest
            samplingStatus = reason or "Available"
        else
            samplingStatus = "ReadFailed"
            samplingError = stringifyReason(latest)
        end
    end

    local behaviorComposition, getBehaviorStatus, behaviorReason = getBehaviorCompositionMethod(self, "GetStatus")
    local behaviorStatus = {
        status = "Unavailable",
        reason = behaviorReason,
    }

    if getBehaviorStatus then
        local behaviorOk, behaviorResult = pcall(
            getBehaviorStatus,
            behaviorComposition
        )

        if behaviorOk and type(behaviorResult) == "table" then
            behaviorStatus = behaviorResult
        elseif behaviorOk then
            behaviorStatus = {
                status = "InvalidStatus",
                reason = "GetStatusMustReturnTable",
            }
        else
            behaviorStatus = {
                status = "ReadFailed",
                reason = stringifyReason(behaviorResult),
            }
        end
    end

    return {
        status = coreStatus,
        capabilities = navigationCore:GetCapabilities(),

        errors = combinedErrors,
        initializationErrors = initializationErrors,
        initializationStatus =
            #initializationErrors > 0 and "Degraded" or "Ready",

        behavior = behaviorStatus,

        sampling = sampling,
        samplingStatus = samplingStatus,
        samplingError = samplingError,

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
