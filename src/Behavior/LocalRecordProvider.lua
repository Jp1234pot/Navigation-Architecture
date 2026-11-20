-- Navigation Architecture v2.2
-- Module: LocalRecordProvider
--
-- Builds the local observation record required by Foundation J.
-- Uses only client-side, read-only character observation.
--
-- Dependencies remain caller-owned.

local LocalRecordProvider = {}
LocalRecordProvider.__index = LocalRecordProvider

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

function LocalRecordProvider.new(dependencies)
    assert(type(dependencies) == "table",
        "LocalRecordProvider requires dependencies")

    assert(
        hasMethods(dependencies.characterManager, {
            "GetCharacter",
            "IsAlive",
        }),
        "Compatible CharacterManager required"
    )

    assert(
        hasMethods(dependencies.physicsObserver, {
            "Observe",
        }),
        "Compatible PhysicsObserver required"
    )

    assert(
        hasMethods(dependencies.velocityEstimator, {
            "Update",
            "GetEstimate",
        }),
        "Compatible VelocityEstimator required"
    )

    return setmetatable({
        CharacterManager = dependencies.characterManager,
        PhysicsObserver = dependencies.physicsObserver,
        VelocityEstimator = dependencies.velocityEstimator,

        _latest = nil,
        _destroyed = false,
    }, LocalRecordProvider)
end

function LocalRecordProvider:BuildLocalRecord()
    if self._destroyed then
        return nil, "Destroyed"
    end

    self._latest = nil

    local characterOk, character = pcall(function()
        return self.CharacterManager:GetCharacter()
    end)

    if not characterOk or not character then
        return nil, "CharacterUnavailable"
    end

    local aliveOk, alive = pcall(function()
        return self.CharacterManager:IsAlive(character)
    end)

    if not aliveOk or alive ~= true then
        return nil, "CharacterNotAlive"
    end

    local observationOk, snapshot, observationReason =
        pcall(function()
            return self.PhysicsObserver:Observe(character)
        end)

    if not observationOk then
        return nil, "ObservationError:" .. tostring(snapshot)
    end

    if type(snapshot) ~= "table" then
        return nil, observationReason or "ObservationUnavailable"
    end

    if snapshot.model ~= character then
        return nil, "ObservationModelMismatch"
    end

    local updateOk, estimate, estimateReason =
        pcall(function()
            return self.VelocityEstimator:Update(snapshot)
        end)

    if not updateOk then
        return nil, "VelocityUpdateError:" .. tostring(estimate)
    end

    -- The first valid observation may not yet have enough samples
    -- to produce an estimate. That is not a failed observation.
    if type(estimate) ~= "table" then
        local getOk, previousEstimate = pcall(function()
            return self.VelocityEstimator:GetEstimate(character)
        end)

        if getOk then
            estimate = previousEstimate
        end
    end

    local record = {
        model = character,
        snapshot = snapshot,
        estimate = estimate,
        timestamp = os.clock(),
        estimateStatus = estimateReason or "OK",
    }

    self._latest = record

    return record, "OK"
end

function LocalRecordProvider:GetLatest()
    if self._destroyed then
        return nil, "Destroyed"
    end

    if not self._latest then
        return nil, "NoLocalRecord"
    end

    return self._latest, "OK"
end

function LocalRecordProvider:Reset()
    if self._destroyed then
        return false, "Destroyed"
    end

    self._latest = nil

    return true, "Reset"
end

function LocalRecordProvider:Destroy()
    if self._destroyed then
        return
    end

    -- Injected dependencies remain caller-owned.
    self._latest = nil

    self.CharacterManager = nil
    self.PhysicsObserver = nil
    self.VelocityEstimator = nil

    self._destroyed = true
end

return LocalRecordProvider
