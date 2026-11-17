-- Navigation Architecture v2.2
-- Module: SamplingCoordinator
-- Client-only, read-only telemetry scheduler for Foundation C observers.
-- This module never selects targets automatically and never writes game state.

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local SamplingCoordinator = {}
SamplingCoordinator.__index = SamplingCoordinator

local function isFiniteNumber(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function copyRecord(record)
	if type(record) == "table" then
		local result = {}
		for key, value in pairs(record) do
			result[key] = value
		end
		return result
	end
	return record
end

local function hasMethod(object, methodName)
	if object ~= nil then
		local success, method = pcall(function()
			return object[methodName]
		end)
		if success and type(method) == "function" then
			return true
		end
	end
	return false
end

local function safeReset(estimator, model)
	if model ~= nil then
		local success, result = pcall(function()
			return estimator:Reset(model)
		end)
		return success and result ~= false
	end
	return false
end

local function isModelInWorkspace(model)
	if typeof(model) == "Instance" then
		local success, result = pcall(function()
			return model:IsA("Model") and model:IsDescendantOf(Workspace)
		end)
		return success and result == true
	end
	return false
end

local function makeUnavailableLocalRecord(status)
	return {
		model = nil,
		snapshot = nil,
		estimate = nil,
		observeStatus = status,
		estimateStatus = "NotSampled",
	}
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

	local configOk, sampleInterval, targetMode = pcall(function()
		return config.telemetrySampleInterval, config.targetMode
	end)

	assert(configOk, "SamplingCoordinator could not read config")
	assert(isFiniteNumber(sampleInterval) and sampleInterval >= 0.05 and sampleInterval <= 2.0, "telemetrySampleInterval must be between 0.05 and 2.0 seconds")
	assert(targetMode == "Player" or targetMode == "NPC", "targetMode must be Player or NPC")

	local playerOk, isPlayer = pcall(function()
		return typeof(player) == "Instance" and player:IsA("Player")
	end)

	assert(playerOk and isPlayer, "SamplingCoordinator requires LocalPlayer")
	assert(hasMethod(characterManager, "GetCharacter") and hasMethod(characterManager, "IsAlive"), "SamplingCoordinator requires CharacterManager methods")
	assert(hasMethod(targetDiscovery, "IsCandidateCurrent"), "SamplingCoordinator requires TargetDiscovery methods")
	assert(hasMethod(physicsObserver, "Observe") and hasMethod(physicsObserver, "ObservePosition"), "SamplingCoordinator requires PhysicsObserver methods")
	assert(hasMethod(velocityEstimator, "Update") and hasMethod(velocityEstimator, "Reset"), "SamplingCoordinator requires VelocityEstimator methods")

	local heartbeatOk, heartbeat = pcall(function()
		return runService.Heartbeat
	end)

	assert(heartbeatOk and hasMethod(heartbeat, "Connect"), "SamplingCoordinator requires RunService.Heartbeat")

	return setmetatable({
		Config = config,
		Player = player,
		CharacterManager = characterManager,
		TargetDiscovery = targetDiscovery,
		PhysicsObserver = physicsObserver,
		VelocityEstimator = velocityEstimator,
		RunService = runService,
		Heartbeat = heartbeat,
		SampleInterval = sampleInterval,
		TargetMode = targetMode,
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
	if not self._destroyed then
		if callback == nil or type(callback) == "function" then
			self.OnSample = callback
			return true, "OK"
		else
			return false, "CallbackMustBeFunctionOrNil"
		end
	end
	return false, "Destroyed"
end

function SamplingCoordinator:SetTarget(candidate, targetMode)
	if not self._destroyed then
		if candidate == nil then
			return self:ClearTarget("ClearedByCaller")
		else
			if type(candidate) == "table" then
				local copyOk, copiedCandidate, candidateModel, candidateKind = pcall(function()
					local copied = copyRecord(candidate)
					return copied, copied.model, copied.kind
				end)

				if copyOk and type(copiedCandidate) == "table" and candidateModel ~= nil then
					local mode = targetMode or self.TargetMode
					if mode == "Player" or mode == "NPC" then
						if mode == self.TargetMode and candidateKind == mode then
							local validationOk, isCurrent, validationStatus = pcall(function()
								return self.TargetDiscovery:IsCandidateCurrent(copiedCandidate, mode)
							end)

							if validationOk then
								if isCurrent then
									local previous = self.SelectedCandidate
									if not previous or previous.model ~= candidateModel or previous.kind ~= candidateKind then
										if previous and previous.model then
											safeReset(self.VelocityEstimator, previous.model)
										end
										safeReset(self.VelocityEstimator, candidateModel)
									end

									self.SelectedCandidate = copiedCandidate

									if self.Latest then
										self.Latest.target = nil
										self.Latest.targetStatus = "TargetChanged"
									end

									return true, "OK"
								else
									return false, validationStatus or "CandidateNotCurrent"
								end
							else
								return false, "CandidateValidationFailed"
							end
						else
							return false, "TargetModeMismatch"
						end
					else
						return false, "InvalidTargetMode"
					end
				else
					return false, "InvalidCandidate"
				end
			else
				return false, "InvalidCandidate"
			end
		end
	end
	return false, "Destroyed"
end

function SamplingCoordinator:ClearTarget(reason)
	if not self._destroyed then
		local previous = self.SelectedCandidate
		if previous and previous.model then
			safeReset(self.VelocityEstimator, previous.model)
		end

		self.SelectedCandidate = nil

		if self.Latest then
			self.Latest.target = nil
			self.Latest.targetStatus = reason or "NoTarget"
		end

		return true, reason or "NoTarget"
	end
	return false, "Destroyed"
end

function SamplingCoordinator:_sampleModel(model, role)
	if model then
		if isModelInWorkspace(model) then
			local observeOk, snapshot, observeStatus = pcall(function()
				if role == "Target" then
					return self.PhysicsObserver:ObservePosition(model)
				else
					return self.PhysicsObserver:Observe(model)
				end
			end)

			if observeOk then
				if snapshot then
					local estimateOk, estimate, estimateStatus = pcall(function()
						return self.VelocityEstimator:Update(snapshot)
					end)

					if estimateOk then
						return snapshot, "OK", {
							estimate = estimate,
							estimateStatus = estimateStatus,
						}
					else
						return snapshot, "OK", {
							estimate = nil,
							estimateStatus = "EstimatorFailed",
						}
					end
				else
					safeReset(self.VelocityEstimator, model)
					return nil, observeStatus or "ObservationFailed", nil
				end
			else
				safeReset(self.VelocityEstimator, model)
				return nil, "ObservationFailed", nil
			end
		else
			safeReset(self.VelocityEstimator, model)
			return nil, role .. "NotInWorkspace", nil
		end
	end
	return nil, role .. "Unavailable", nil
end

function SamplingCoordinator:_buildLocalRecord()
	local characterOk, character = pcall(function()
		return self.CharacterManager:GetCharacter()
	end)

	if characterOk then
		if character ~= self.LocalCharacter then
			if self.LocalCharacter then
				safeReset(self.VelocityEstimator, self.LocalCharacter)
			end
			self.LocalCharacter = character
			if character then
				safeReset(self.VelocityEstimator, character)
			end
		end

		if character then
			local aliveOk, isAlive = pcall(function()
				return self.CharacterManager:IsAlive(character)
			end)

			if aliveOk and isAlive then
				local snapshot, status, estimateInfo = self:_sampleModel(character, "LocalCharacter")
				return {
					model = character,
					snapshot = snapshot,
					estimate = estimateInfo and estimateInfo.estimate or nil,
					observeStatus = status,
					estimateStatus = estimateInfo and estimateInfo.estimateStatus or "NotSampled",
				}, status
			else
				safeReset(self.VelocityEstimator, character)
				return {
					model = character,
					snapshot = nil,
					estimate = nil,
					observeStatus = "LocalCharacterNotReadyOrAlive",
					estimateStatus = "NotSampled",
				}, "LocalCharacterNotReadyOrAlive"
			end
		else
			return makeUnavailableLocalRecord("LocalCharacterUnavailable"), "LocalCharacterUnavailable"
		end
	end
	return makeUnavailableLocalRecord("CharacterLookupFailed"), "CharacterLookupFailed"
end

function SamplingCoordinator:_buildTargetRecord()
	local candidate = self.SelectedCandidate
	if candidate then
		local model = candidate.model
		local validationOk, isCurrent, validationStatus = pcall(function()
			return self.TargetDiscovery:IsCandidateCurrent(candidate, self.TargetMode)
		end)

		if validationOk then
			if isCurrent then
				local snapshot, observeStatus, estimateInfo = self:_sampleModel(model, "Target")
				return {
					candidate = candidate,
					model = model,
					snapshot = snapshot,
					estimate = estimateInfo and estimateInfo.estimate or nil,
					observeStatus = observeStatus,
					estimateStatus = estimateInfo and estimateInfo.estimateStatus or "NotSampled",
					validationStatus = "OK",
				}, observeStatus
			else
				safeReset(self.VelocityEstimator, model)
				local status = validationStatus or "TargetUnavailable"
				return {
					candidate = candidate,
					model = model,
					snapshot = nil,
					estimate = nil,
					observeStatus = status,
					estimateStatus = "NotSampled",
					validationStatus = status,
				}, status
			end
		else
			safeReset(self.VelocityEstimator, model)
			return {
				candidate = candidate,
				model = model,
				snapshot = nil,
				estimate = nil,
				observeStatus = "CandidateValidationFailed",
				estimateStatus = "NotSampled",
				validationStatus = "CandidateValidationFailed",
			}, "CandidateValidationFailed"
		end
	end
	return nil, "NoTarget"
end

function SamplingCoordinator:_publish(packet)
	self.Latest = packet
	if self.OnSample then
		local callbackOk, callbackError = pcall(self.OnSample, self:GetLatest())
		if not callbackOk then
			warn("[Navigation v2.2] SamplingCoordinator callback failed: " .. tostring(callbackError))
		end
	end
end

function SamplingCoordinator:_sample()
	if not self._destroyed then
		local localOk, localRecord, localStatus = pcall(function()
			return self:_buildLocalRecord()
		end)

		if not localOk then
			localRecord = makeUnavailableLocalRecord("LocalSamplingFailed")
			localStatus = "LocalSamplingFailed"
		end

		local targetOk, targetRecord, targetStatus = pcall(function()
			return self:_buildTargetRecord()
		end)

		if not targetOk then
			targetRecord = nil
			targetStatus = "TargetSamplingFailed"
		end

		self:_publish({
			timestamp = os.clock(),
			sampleInterval = self.SampleInterval,
			status = localRecord.snapshot and "OK" or localStatus,
			localCharacter = localRecord,
			target = targetRecord,
			targetStatus = targetStatus,
		})
	end
end

function SamplingCoordinator:Start()
	if not self._destroyed then
		if self._connection then
			local stateOk, connected = pcall(function()
				return self._connection.Connected
			end)

			if stateOk then
				if connected then
					return false, "AlreadyRunning"
				else
					self._connection = nil
				end
			else
				return false, "ConnectionStateUnavailable"
			end
		end

		self._accumulator = 0

		local connectOk, connection = pcall(function()
			return self.Heartbeat:Connect(function(deltaTime)
				if not self._destroyed then
					if isFiniteNumber(deltaTime) and deltaTime > 0 then
						self._accumulator += deltaTime
						if self._accumulator >= self.SampleInterval then
							self._accumulator = 0
							local sampleOk, sampleError = pcall(function()
								self:_sample()
							end)
							if not sampleOk then
								warn("[Navigation v2.2] SamplingCoordinator sample failed: " .. tostring(sampleError))
							end
						end
					end
				end
			end)
		end)

		if connectOk and connection ~= nil then
			local connectionOk, connected, disconnectMethod = pcall(function()
				return connection.Connected, connection.Disconnect
			end)

			if connectionOk and connected == true and type(disconnectMethod) == "function" then
				self._connection = connection
				return true, "Started"
			else
				pcall(function()
					connection:Disconnect()
				end)
				self._connection = nil
				return false, "InvalidHeartbeatConnection"
			end
		else
			self._connection = nil
			return false, "HeartbeatConnectionFailed"
		end
	end
	return false, "Destroyed"
end

function SamplingCoordinator:Stop()
	local connection = self._connection
	self._connection = nil
	self._accumulator = 0

	if connection then
		local disconnectOk = pcall(function()
			connection:Disconnect()
		end)
		if not disconnectOk then
			warn("[Navigation v2.2] SamplingCoordinator disconnect failed")
		end
	end

	return true, "Stopped"
end

function SamplingCoordinator:GetLatest()
	if self.Latest then
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
	return nil
end

function SamplingCoordinator:Destroy()
	if not self._destroyed then
		self._destroyed = true
		self:Stop()

		if self.LocalCharacter then
			safeReset(self.VelocityEstimator, self.LocalCharacter)
		end

		if self.SelectedCandidate and self.SelectedCandidate.model then
			safeReset(self.VelocityEstimator, self.SelectedCandidate.model)
		end

		self.SelectedCandidate = nil
		self.LocalCharacter = nil
		self.Latest = nil
		self.OnSample = nil
	end
end

return SamplingCoordinator
