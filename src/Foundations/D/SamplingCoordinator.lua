
-- Navigation Architecture v2.2
-- Module: SamplingCoordinator
-- Client-only, read-only telemetry scheduler for Foundation C observers.
-- This module never selects targets automatically and never writes game state.

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local SamplingCoordinator = {}
SamplingCoordinator.__index = SamplingCoordinator

local function copyRecord(record)
    if type(record) ~= "table" then
        return record
    end
    local result = {}
    for key, value in pairs(record) do
        result[key] = value
    end
    return result
end

local function isModelInWorkspace(model)
    if typeof(model) ~= "Instance" then
        return false
    end

    local success, result = pcall(function()
        return model:IsA("Model") and model:IsDescendantOf(Workspace)
    end)
    return success and result == true
end

function SamplingCoordinator.new(dependencies)
    assert(type(dependencies) == "table", "SamplingCoordinator requires dependencies")

    local config = dependencies.config
    local player = dependencies.player
    local characterManager = dependencies.characterManager
    local targetDiscovery = dependencies.targetDiscovery
    local physicsObserver = dependencies.physicsObserver
    local velocityEstimator = dependencies.velocityEstimator
    local runService = dependencies.runService or RunService

    assert(type(config) == "table", "SamplingCoordinator requires config")
    assert(type(config.telemetrySampleInterval) == "number"
        and config.telemetrySampleInterval >= 0.05
        and config.telemetrySampleInterval <= 2.0,
        "telemetrySampleInterval must be between 0.05 and 2.0 seconds")
    assert(player and player:IsA("Player"), "SamplingCoordinator requires LocalPlayer")
    assert(characterManager ~= nil, "SamplingCoordinator requires CharacterManager")
    assert(targetDiscovery ~= nil, "SamplingCoordinator requires TargetDiscovery")
    assert(physicsObserver ~= nil, "SamplingCoordinator requires PhysicsObserver")
    assert(velocityEstimator ~= nil, "SamplingCoordinator requires VelocityEstimator")
    assert(runService and runService.Heartbeat, "SamplingCoordinator requires RunService.Heartbeat")

    return setmetatable({
        Config = config,
        Player = player,
        CharacterManager = characterManager,
        TargetDiscovery = targetDiscovery,
        PhysicsObserver = physicsObserver,
        VelocityEstimator = velocityEstimator,
        RunService = runService,
        SampleInterval = config.telemetrySampleInterval,
        SelectedCandidate = nil,
        LocalCharacter = nil,
        Latest = nil,
        OnSample = nil,
        _connection = nil,
        _accumulator = 0,
        _destroyed = false,
    }, SamplingCoordinator)
end

function SamplingCoordinator:SetOnSample(callback)
    if self._destroyed then
        return false, "Destroyed"
    end
    if callback ~= nil and type(callback) ~= "function" then
        return false, "CallbackMustBeFunctionOrNil"
    end
    self.OnSample = callback
    return true, "OK"
end

-- Target selection is explicit. The supplied candidate must originate from
-- TargetDiscovery and must still pass its current faction/presence checks.
function SamplingCoordinator:SetTarget(candidate, targetMode)
    if self._destroyed then
        return false, "Destroyed"
    end
    if candidate == nil then
        return self:ClearTarget("ClearedByCaller")
    end
    if type(candidate) ~= "table" or not candidate.model then
        return false, "InvalidCandidate"
    end

    candidate = copyRecord(candidate)

    local mode = targetMode or self.Config.targetMode
    if mode ~= "Player" and mode ~= "NPC" then
        return false, "InvalidTargetMode"
    end
    if mode ~= self.Config.targetMode then
        return false, "TargetModeMismatch"
    end
    if candidate.kind ~= mode then
        return false, "TargetModeMismatch"
    end

    local success, isCurrent, status = pcall(function()
        local current, currentStatus = self.TargetDiscovery:IsCandidateCurrent(candidate, mode)
        return current, currentStatus
    end)
    if not success then
        return false, "CandidateValidationFailed"
    end
    if not isCurrent then
        return false, status or "CandidateNotCurrent"
    end

    local previous = self.SelectedCandidate
    if not previous or previous.model ~= candidate.model or previous.kind ~= candidate.kind then
        if previous and previous.model then
            self.VelocityEstimator:Reset(previous.model)
        end
        self.VelocityEstimator:Reset(candidate.model)
    end

    self.SelectedCandidate = candidate
    if self.Latest then
        self.Latest.target = nil
        self.Latest.targetStatus = "TargetChanged"
    end
    return true, "OK"
end

function SamplingCoordinator:ClearTarget(reason)
    if self._destroyed then
        return false, "Destroyed"
    end
    local previous = self.SelectedCandidate
    if previous and previous.model then
        self.VelocityEstimator:Reset(previous.model)
    end
    self.SelectedCandidate = nil
    if self.Latest then
        self.Latest.target = nil
        self.Latest.targetStatus = reason or "NoTarget"
    end
    return true, reason or "NoTarget"
end

function SamplingCoordinator:_sampleModel(model, role)
    if not model then
        return nil, role .. "Unavailable", nil
    end
    if not isModelInWorkspace(model) then
        self.VelocityEstimator:Reset(model)
        return nil, role .. "NotInWorkspace", nil
    end

    local snapshot, observeStatus = self.PhysicsObserver:Observe(model)
    if not snapshot then
        self.VelocityEstimator:Reset(model)
        return nil, observeStatus or "ObservationFailed", nil
    end

    local estimate, estimateStatus = self.VelocityEstimator:Update(snapshot)
    return snapshot, "OK", {
        estimate = estimate,
        estimateStatus = estimateStatus,
    }
end

function SamplingCoordinator:_buildLocalRecord()
    local character = self.CharacterManager:GetCharacter()
    if character ~= self.LocalCharacter then
        if self.LocalCharacter then
            self.VelocityEstimator:Reset(self.LocalCharacter)
        end
        self.LocalCharacter = character
        if character then
            self.VelocityEstimator:Reset(character)
        end
    end

    if not character then
        return {
            model = nil,
            snapshot = nil,
            estimate = nil,
            observeStatus = "LocalCharacterUnavailable",
            estimateStatus = "NotSampled",
        }, "LocalCharacterUnavailable"
    end

    local aliveOk, isAlive = pcall(function()
        return self.CharacterManager:IsAlive(character)
    end)
    if not aliveOk or not isAlive then
        self.VelocityEstimator:Reset(character)
        return {
            model = character,
            snapshot = nil,
            estimate = nil,
            observeStatus = "LocalCharacterNotReadyOrAlive",
            estimateStatus = "NotSampled",
        }, "LocalCharacterNotReadyOrAlive"
    end

    local snapshot, status, estimateInfo = self:_sampleModel(character, "LocalCharacter")
    return {
        model = character,
        snapshot = snapshot,
        estimate = estimateInfo and estimateInfo.estimate or nil,
        observeStatus = status,
        estimateStatus = estimateInfo and estimateInfo.estimateStatus or "NotSampled",
    }, status
end

function SamplingCoordinator:_buildTargetRecord()
    local candidate = self.SelectedCandidate
    if not candidate then
        return nil, "NoTarget"
    end

    local mode = self.Config.targetMode
    local success, isCurrent, validationStatus = pcall(function()
        local current, currentStatus = self.TargetDiscovery:IsCandidateCurrent(candidate, mode)
        return current, currentStatus
    end)

    if not success then
        self.VelocityEstimator:Reset(candidate.model)
        return {
            candidate = candidate,
            model = candidate.model,
            snapshot = nil,
            estimate = nil,
            observeStatus = "CandidateValidationFailed",
            estimateStatus = "NotSampled",
            validationStatus = "CandidateValidationFailed",
        }, "CandidateValidationFailed"
    end

    if not isCurrent then
        -- Keep the explicit selection while unavailable. Streaming or temporary
        -- replication gaps are not treated as proof that the target was removed.
        self.VelocityEstimator:Reset(candidate.model)
        return {
            candidate = candidate,
            model = candidate.model,
            snapshot = nil,
            estimate = nil,
            observeStatus = validationStatus or "TargetUnavailable",
            estimateStatus = "NotSampled",
            validationStatus = validationStatus or "TargetUnavailable",
        }, validationStatus or "TargetUnavailable"
    end

    local snapshot, observeStatus, estimateInfo = self:_sampleModel(candidate.model, "Target")
    return {
        candidate = candidate,
        model = candidate.model,
        snapshot = snapshot,
        estimate = estimateInfo and estimateInfo.estimate or nil,
        observeStatus = observeStatus,
        estimateStatus = estimateInfo and estimateInfo.estimateStatus or "NotSampled",
        validationStatus = "OK",
    }, observeStatus
end

function SamplingCoordinator:_publish(packet)
    self.Latest = packet
    if self.OnSample then
        local success, err = pcall(self.OnSample, self:GetLatest())
        if not success then
            warn("[Navigation v2.2] SamplingCoordinator callback failed: " .. tostring(err))
        end
    end
end

function SamplingCoordinator:_sample()
    if self._destroyed then
        return
    end

    local localRecord, localStatus = self:_buildLocalRecord()
    local targetRecord, targetStatus = self:_buildTargetRecord()

    self:_publish({
        timestamp = os.clock(),
        sampleInterval = self.SampleInterval,
        status = localRecord.snapshot and "OK" or localStatus,
        localCharacter = localRecord,
        target = targetRecord,
        targetStatus = targetStatus,
    })
end

function SamplingCoordinator:Start()
    if self._destroyed then
        return false, "Destroyed"
    end
    if self._connection and self._connection.Connected then
        return false, "AlreadyRunning"
    end

    self._accumulator = 0
    self._connection = self.RunService.Heartbeat:Connect(function(deltaTime)
        if self._destroyed then
            return
        end
        if type(deltaTime) ~= "number" or deltaTime ~= deltaTime
            or deltaTime == math.huge or deltaTime == -math.huge or deltaTime <= 0 then
            return
        end

        self._accumulator = self._accumulator + deltaTime
        if self._accumulator >= self.SampleInterval then
            -- Do one sample, not a catch-up burst, after a slow frame.
            self._accumulator = 0
            self:_sample()
        end
    end)

    return true, "Started"
end

function SamplingCoordinator:Stop()
    if self._connection then
        if self._connection.Connected then
            self._connection:Disconnect()
        end
        self._connection = nil
    end
    self._accumulator = 0
    return true, "Stopped"
end

function SamplingCoordinator:GetLatest()
    if not self.Latest then
        return nil
    end
    local result = copyRecord(self.Latest)
    result.localCharacter = copyRecord(self.Latest.localCharacter)
    if result.localCharacter then
        result.localCharacter.snapshot = copyRecord(self.Latest.localCharacter.snapshot)
        result.localCharacter.estimate = copyRecord(self.Latest.localCharacter.estimate)
    end
    result.target = copyRecord(self.Latest.target)
    if result.target then
        result.target.candidate = copyRecord(self.Latest.target.candidate)
        result.target.snapshot = copyRecord(self.Latest.target.snapshot)
        result.target.estimate = copyRecord(self.Latest.target.estimate)
    end
    return result
end

function SamplingCoordinator:Destroy()
    if self._destroyed then
        return
    end
    self:Stop()
    if self.LocalCharacter then
        self.VelocityEstimator:Reset(self.LocalCharacter)
    end
    if self.SelectedCandidate and self.SelectedCandidate.model then
        self.VelocityEstimator:Reset(self.SelectedCandidate.model)
    end
    self.SelectedCandidate = nil
    self.LocalCharacter = nil
    self.Latest = nil
    self.OnSample = nil
    self._destroyed = true
end

return SamplingCoordinator
