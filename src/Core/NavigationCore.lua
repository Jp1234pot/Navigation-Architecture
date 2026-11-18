-- Navigation Architecture v2.2
-- Module: NavigationCore
-- Shared coordination layer for injected A-K foundation modules.
--
-- Responsibilities:
--   - Validate injected public interfaces.
--   - Report capability availability.
--   - Track initialization and validation errors.
--   - Provide controlled public module access.
--   - Preserve caller ownership of injected modules.
--   - Isolate Core configuration from caller mutation.
--
-- This module does not construct, start, stop, or destroy injected modules.

local NavigationCore = {}
NavigationCore.__index = NavigationCore

local MODULE_INTERFACES = {
    StateManager = {
        "GetState", "GetLastReason", "SetState", "Destroy",
    },
    LifecycleManager = {
        "Connect", "Disconnect", "AddCleanup", "Destroy",
    },
    CharacterManager = {
        "GetCharacter", "GetHumanoid", "GetRoot",
        "IsAlive", "IsAnchored", "Destroy",
    },
    FactionValidator = {
        "GetPlayerFaction", "GetModelFaction",
        "Classify", "IsEligible",
    },
    TargetDiscovery = {
        "GetCandidates", "FindNearest", "IsCandidateCurrent",
    },
    PhysicsObserver = {
        "Observe", "ObservePosition", "Destroy",
    },
    VelocityEstimator = {
        "Update", "GetEstimate", "Reset", "Destroy",
    },
    SamplingCoordinator = {
        "SetOnSample", "SetTarget", "ClearTarget",
        "Start", "Stop", "GetLatest", "Destroy",
    },
    TelemetryPanel = {
        "Update", "SetVisible", "Destroy",
    },
    PathfindingEngine = {
        "SetOnResult", "SetOnBlocked", "SetOnUnblocked",
        "RequestPath", "Cancel", "GetLatest", "Destroy",
    },
    WaypointTracker = {
        "SetPath", "Update", "GetProgress", "Reset", "Destroy",
    },
    MovementController = {
        "SetOnStatus", "GetStatus", "Start", "Stop", "Destroy",
    },
    AdaptiveRepath = {
        "Consider", "ReportOutcome", "GetState", "Reset", "Destroy",
    },
    RecoveryAnalysis = {
        "Record", "GetRecent", "GetSummary", "Reset", "Destroy",
    },
    MultiThreatAnalysis = {
        "Analyze", "Destroy",
    },
    LocalRecordProvider = {
        "BuildLocalRecord", "GetLatest", "Reset", "Destroy",
    },
    ConfidenceLedger = {
        "Record", "Assess", "GetRecent", "GetSummary", "Reset", "Destroy",
    },
    DecisionLedger = {
        "Record", "GetRecent", "GetSummary", "Reset", "Destroy",
    },
    UncertaintyMap = {
        "Observe", "GetAt", "GetCells", "GetSummary", "Reset", "Destroy",
    },
    BehaviorDecision = {
        "Evaluate", "SetMode", "GetLatest", "Reset", "Destroy",
    },
    EscapeDestinationEvaluator = {
        "Evaluate", "GetLatest", "Reset", "Destroy",
    },
    BehaviorRouteCoordinator = {
        "RequestRoute", "AcceptPathResult", "UpdateProgress", "Cancel", "GetStatus", "Destroy",
    },
    BehaviorCoordinator = {
        "Process", "SetMode", "GetLatest", "GetStatus", "AcceptPathResult", "UpdateProgress", "Cancel", "Reset", "Destroy",
    },
    BehaviorComposition = {
        "SetMode",
        "GetMode",
        "ProcessOnce",
        "AcceptPathResult",
        "UpdateProgress",
        "GetLatest",
        "GetStatus",
        "Cancel",
        "Reset",
        "Destroy",
    },
}

-- These are the only configuration fields consumed by NavigationCore.
local CORE_CONFIG_KEYS = {
    "enabled",
    "pathfindingEnabled",
    "movementEnabled",
    "adaptiveRepathEnabled",
    "multiThreatAnalysisEnabled",
    "evidenceLedgerEnabled",
    "telemetryPanelEnabled",
}

local CAPABILITY_DEFINITIONS = {
    TargetDiscovery = {
        modules = {"FactionValidator", "TargetDiscovery"},
        enabled = function(config)
            return config.enabled
        end,
    },

    PhysicalObservation = {
        modules = {"PhysicsObserver"},
        enabled = function(config)
            return config.enabled
        end,
    },

    VelocityAnalysis = {
        modules = {"PhysicsObserver", "VelocityEstimator"},
        enabled = function(config)
            return config.enabled
        end,
    },

    CoordinatedSampling = {
        modules = {
            "CharacterManager",
            "TargetDiscovery",
            "PhysicsObserver",
            "VelocityEstimator",
            "SamplingCoordinator",
        },
        enabled = function(config)
            return config.enabled
        end,
    },

    TelemetryPresentation = {
        modules = {"TelemetryPanel"},
        enabled = function(config)
            return config.telemetryPanelEnabled
        end,
    },

    PathComputation = {
        modules = {"PathfindingEngine"},
        enabled = function(config)
            return config.pathfindingEnabled
        end,
    },

    WaypointProgress = {
        modules = {"WaypointTracker"},
        enabled = function(config)
            return config.pathfindingEnabled
        end,
    },

    LocalMovement = {
        modules = {"CharacterManager", "MovementController"},
        enabled = function(config)
            return config.movementEnabled
        end,
    },

    RecoveryAnalysis = {
        modules = {"RecoveryAnalysis"},
        enabled = function(config)
            return config.adaptiveRepathEnabled
        end,
    },

    AdaptiveRepath = {
        modules = {"AdaptiveRepath"},
        enabled = function(config)
            return config.adaptiveRepathEnabled
        end,
    },

    ThreatAnalysis = {
        modules = {
            "TargetDiscovery",
            "PhysicsObserver",
            "VelocityEstimator",
            "MultiThreatAnalysis",
        },
        enabled = function(config)
            return config.multiThreatAnalysisEnabled
        end,
    },

    BehaviorDecision = {
        modules = {
            "MultiThreatAnalysis",
            "BehaviorDecision",
        },
        enabled = function(config)
            return config.multiThreatAnalysisEnabled
        end,
    },

    EscapeDestinationEvaluation = {
        modules = {
            "CharacterManager",
            "BehaviorDecision",
            "EscapeDestinationEvaluator",
        },
        enabled = function(config)
            return config.multiThreatAnalysisEnabled
        end,
    },

    BehaviorRouteCoordination = {
        modules = {
            "CharacterManager",
            "PathfindingEngine",
            "WaypointTracker",
            "BehaviorRouteCoordinator",
        },
        enabled = function(config)
            return config.pathfindingEnabled
        end,
    },

    BehaviorCoordination = {
        modules = {
            "CharacterManager",
            "PathfindingEngine",
            "WaypointTracker",
            "MultiThreatAnalysis",
            "LocalRecordProvider",
            "BehaviorDecision",
            "EscapeDestinationEvaluator",
            "BehaviorRouteCoordinator",
            "BehaviorCoordinator",
            "BehaviorComposition",
        },
        enabled = function(config)
            return config.enabled
                and config.multiThreatAnalysisEnabled
                and config.pathfindingEnabled
        end,
    },

    ConfidenceAssessment = {
        modules = {"ConfidenceLedger"},
        enabled = function(config)
            return config.evidenceLedgerEnabled
        end,
    },

    DecisionRecording = {
        modules = {"DecisionLedger"},
        enabled = function(config)
            return config.evidenceLedgerEnabled
        end,
    },

    UncertaintyTracking = {
        modules = {"UncertaintyMap"},
        enabled = function(config)
            return config.evidenceLedgerEnabled
        end,
    },
}

local function copyRecord(source)
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

local function validateConfig(config)
    if type(config) ~= "table" then
        return false, "ConfigMustBeTable"
    end

    for _, key in ipairs(CORE_CONFIG_KEYS) do
        local ok, value = pcall(function()
            return config[key]
        end)

        if not ok or type(value) ~= "boolean" then
            return false, "InvalidConfigField:" .. key
        end
    end

    return true, "OK"
end

local function createConfigSnapshot(config)
    local snapshot = {}

    for _, key in ipairs(CORE_CONFIG_KEYS) do
        snapshot[key] = config[key]
    end

    -- Core configuration is immutable after construction.
    return table.freeze(snapshot)
end

local function validateModule(name, module)
    if type(module) ~= "table" then
        return false, "ModuleMustBeTable"
    end

    local requiredMethods = MODULE_INTERFACES[name]

    if not requiredMethods then
        return false, "UnknownModule"
    end

    for _, methodName in ipairs(requiredMethods) do
        local ok, method = pcall(function()
            return module[methodName]
        end)

        if not ok or type(method) ~= "function" then
            return false, "MissingRequiredMethod:" .. methodName
        end
    end

    return true, "OK"
end

local function validateModules(modules)
    local validModules = {}
    local errors = {}

    if type(modules) ~= "table" then
        errors[#errors + 1] = {
            module = "modules",
            capability = "Core",
            stage = "Validation",
            reason = "ModulesMustBeTable",
        }

        return validModules, errors
    end

    for name, module in pairs(modules) do
        if type(name) ~= "string" or not MODULE_INTERFACES[name] then
            errors[#errors + 1] = {
                module = tostring(name),
                capability = "Core",
                stage = "ModuleValidation",
                reason = "UnknownModule",
            }
        else
            local valid, reason = validateModule(name, module)

            if valid then
                validModules[name] = module
            else
                errors[#errors + 1] = {
                    module = name,
                    capability = "Core",
                    stage = "ModuleValidation",
                    reason = reason,
                }
            end
        end
    end

    return validModules, errors
end

local function buildCapabilities(config, modules)
    local capabilities = {}

    for name, definition in pairs(CAPABILITY_DEFINITIONS) do
        local missingModules = {}

        for _, moduleName in ipairs(definition.modules) do
            if modules[moduleName] == nil then
                missingModules[#missingModules + 1] = moduleName
            end
        end

        local enabled = definition.enabled(config)
        local available = #missingModules == 0

        local reason = "OK"

        if not available then
            reason = "MissingDependency"
        elseif not enabled then
            reason = "DisabledByConfiguration"
        end

        capabilities[name] = {
            available = available,
            enabled = enabled,
            usable = available and enabled,
            reason = reason,
            missingModules = missingModules,
        }
    end

    return capabilities
end

local function buildCapabilityErrors(capabilities)
    local errors = {}

    for name, capability in pairs(capabilities) do
        if capability.enabled and not capability.available then
            errors[#errors + 1] = {
                module = nil,
                capability = name,
                stage = "CapabilityValidation",
                reason = capability.reason,
                missingModules = table.clone(capability.missingModules),
            }
        end
    end

    return errors
end

function NavigationCore.new(dependencies)
    assert(type(dependencies) == "table",
        "NavigationCore requires a dependency package")

    local config = dependencies.config
    local configValid, configReason = validateConfig(config)

    assert(configValid, configReason)

    -- Snapshot only the fields consumed by Core.
    -- Later caller-side mutations cannot alter Core capability decisions.
    local configSnapshot = createConfigSnapshot(config)

    local suppliedModules = dependencies.modules

    if suppliedModules == nil then
        suppliedModules = {}
    end

    local validModules, moduleErrors = validateModules(suppliedModules)

    local capabilities = buildCapabilities(
        configSnapshot,
        validModules
    )

    local capabilityErrors = buildCapabilityErrors(capabilities)

    local errors = {}

    for _, err in ipairs(moduleErrors) do
        errors[#errors + 1] = err
    end

    for _, err in ipairs(capabilityErrors) do
        errors[#errors + 1] = err
    end

    -- Only missing dependencies of enabled capabilities degrade Core.
    -- Unrelated invalid or unknown modules remain visible in GetErrors()
    -- without disabling otherwise usable capabilities.
    local degraded = #capabilityErrors > 0
    local status = degraded and "Degraded" or "Ready"

    return setmetatable({
        Config = configSnapshot,

        _modules = validModules,
        _capabilities = capabilities,
        _errors = errors,

        _status = status,
        _initialized = true,
        _degraded = degraded,
        _destroyed = false,
    }, NavigationCore)
end

function NavigationCore:GetStatus()
    return {
        status = self._destroyed and "Stopped" or self._status,
        initialized = self._initialized,
        degraded = self._degraded,
        destroyed = self._destroyed,
    }
end

function NavigationCore:GetCapabilities()
    if self._destroyed then
        return {}, "Destroyed"
    end

    return copyRecord(self._capabilities), "OK"
end

function NavigationCore:GetModule(name)
    if self._destroyed then
        return nil, "Destroyed"
    end

    if type(name) ~= "string" then
        return nil, "InvalidModuleName"
    end

    local module = self._modules[name]

    if module == nil then
        return nil, "ModuleUnavailable"
    end

    return module, "OK"
end

function NavigationCore:GetErrors()
    return copyRecord(self._errors)
end

function NavigationCore:Destroy()
    if self._destroyed then
        return false, "AlreadyDestroyed"
    end

    -- Injected modules remain caller-owned.
    self._destroyed = true

    table.clear(self._modules)
    table.clear(self._capabilities)
    table.clear(self._errors)

    self.Config = nil
    self._status = "Stopped"

    return true, "Stopped"
end

return NavigationCore
