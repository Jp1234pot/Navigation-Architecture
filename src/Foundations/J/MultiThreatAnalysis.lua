
-- Navigation Architecture v2.2
-- Foundation J: MultiThreatAnalysis
-- Client-only, read-only, bounded proximity and trajectory assessment.
-- This module does not infer intent, select an action, highlight, move, or attack.

local MultiThreatAnalysis = {}
MultiThreatAnalysis.__index = MultiThreatAnalysis

local function isFiniteNumber(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function isFiniteVector3(value)
	return typeof(value) == "Vector3"
		and isFiniteNumber(value.X)
		and isFiniteNumber(value.Y)
		and isFiniteNumber(value.Z)
end

local function isModel(value)
	if typeof(value) == "Instance" then
		local success, result = pcall(function()
			return value:IsA("Model")
		end)
		return success and result == true
	end
	return false
end

local function hasMethods(value, methodNames)
	if type(value) == "table" then
		local success, result = pcall(function()
			for _, methodName in ipairs(methodNames) do
				if type(value[methodName]) ~= "function" then
					return false
				end
			end
			return true
		end)
		return success and result == true
	end
	return false
end

local function clamp(value, minimum, maximum)
	return math.max(minimum, math.min(maximum, value))
end

local function snapshotConfig(config)
	local values = {
		multiThreatAnalysisEnabled = config.multiThreatAnalysisEnabled == true,
		targetMode = config.targetMode,
		maxThreatCandidates = config.maxThreatCandidates,
		maxThreatResults = config.maxThreatResults,
		threatAnalysisMinInterval = config.threatAnalysisMinInterval,
		threatMaxEstimateAge = config.threatMaxEstimateAge,
		threatPredictionHorizon = config.threatPredictionHorizon,
		threatNearDistance = config.threatNearDistance,
		threatCriticalDistance = config.threatCriticalDistance,
		threatMaxApproachSpeed = config.threatMaxApproachSpeed,
	}
	return table.freeze(values)
end

-- An estimate must belong to the expected model, precede its snapshot,
-- and remain fresh relative to the current local clock.
local function getFreshVelocity(estimate, model, snapshotTimestamp, now, maxAge)
	if type(estimate) == "table"
		and estimate.model == model
		and isFiniteVector3(estimate.velocity)
		and isFiniteNumber(estimate.timestamp)
		and isFiniteNumber(snapshotTimestamp)
		and isFiniteNumber(now) then

		local estimateToSnapshotAge = snapshotTimestamp - estimate.timestamp
		local estimateToNowAge = now - estimate.timestamp

		if estimateToSnapshotAge >= 0
			and estimateToNowAge >= 0
			and estimateToNowAge <= maxAge then
			return estimate.velocity, estimate.timestamp
		end
	end
	return nil, nil
end

local function assessContact(
	localPosition,
	localVelocity,
	localVelocityTimestamp,
	candidate,
	snapshot,
	estimate,
	config,
	now
)
	if type(candidate) == "table"
		and isModel(candidate.model)
		and (candidate.kind == "Player" or candidate.kind == "NPC") then

		if type(snapshot) == "table"
			and snapshot.model == candidate.model
			and isFiniteVector3(snapshot.position)
			and isFiniteNumber(snapshot.timestamp) then

			local snapshotAge = now - snapshot.timestamp

			if snapshotAge >= 0 and snapshotAge <= config.threatMaxEstimateAge then
				local offset = snapshot.position - localPosition
				local distance = offset.Magnitude

				if isFiniteNumber(distance) then
					local candidateVelocity, candidateVelocityTimestamp = getFreshVelocity(
						estimate,
						candidate.model,
						snapshot.timestamp,
						now,
						config.threatMaxEstimateAge
					)

					-- Relative velocity is meaningful only when both estimates
					-- are available and were sampled sufficiently close together.
					local estimateSkew = nil
					if localVelocityTimestamp and candidateVelocityTimestamp then
						estimateSkew = math.abs(candidateVelocityTimestamp - localVelocityTimestamp)
					end

					local hasRelativeVelocity =
						localVelocity ~= nil
						and candidateVelocity ~= nil
						and estimateSkew ~= nil
						and estimateSkew <= config.threatAnalysisMinInterval

					local closingSpeed = nil
					local timeToClosestApproach = nil
					local predictedClosestDistance = nil

					if hasRelativeVelocity then
						local relativeVelocity = candidateVelocity - localVelocity
						local relativeSpeedSquared = relativeVelocity:Dot(relativeVelocity)

						if isFiniteNumber(relativeSpeedSquared) and relativeSpeedSquared > 0.0001 then
							local closingRate = -offset:Dot(relativeVelocity) / math.max(distance, 0.001)
							if isFiniteNumber(closingRate) then
								closingSpeed = closingRate
							end

							local time = -offset:Dot(relativeVelocity) / relativeSpeedSquared
							if isFiniteNumber(time)
								and time > 0
								and time <= config.threatPredictionHorizon then

								local closestOffset = offset + relativeVelocity * time
								local closestDistance = closestOffset.Magnitude

								if isFiniteNumber(closestDistance) then
									timeToClosestApproach = time
									predictedClosestDistance = closestDistance
								end
							end
						else
							closingSpeed = 0
						end
					end

					local proximityScore = clamp(
						1 - (distance / config.threatNearDistance),
						0,
						1
					) * 60

					local approachScore = 0
					if closingSpeed and closingSpeed > 0 then
						approachScore = clamp(
							closingSpeed / config.threatMaxApproachSpeed,
							0,
							1
						) * 25
					end

					local trajectoryScore = 0
					if predictedClosestDistance then
						trajectoryScore = clamp(
							1 - (predictedClosestDistance / config.threatNearDistance),
							0,
							1
						) * 15
					end

					local score = math.floor(
						clamp(proximityScore + approachScore + trajectoryScore, 0, 100) + 0.5
					)

					local assessment

					if distance <= config.threatCriticalDistance then
						assessment = "CriticalProximity"
					elseif predictedClosestDistance ~= nil
						and predictedClosestDistance <= config.threatCriticalDistance then
						assessment = "PredictedCriticalPass"
					elseif distance <= config.threatNearDistance then
						assessment = "ElevatedProximity"
					elseif predictedClosestDistance ~= nil
						and predictedClosestDistance <= config.threatNearDistance then
						assessment = "PredictedNearPass"
					elseif closingSpeed ~= nil and closingSpeed >= 2 then
						assessment = "Approaching"
					else
						assessment = "Distant"
					end

					return {
						model = candidate.model,
						player = candidate.player,
						kind = candidate.kind,
						classification = candidate.classification or "Unclassified",
						distance = distance,
						closingSpeed = closingSpeed,
						timeToClosestApproach = timeToClosestApproach,
						predictedClosestDistance = predictedClosestDistance,
						velocityAvailable = hasRelativeVelocity,
						score = score,
						assessment = assessment,
						sampleTimestamp = snapshot.timestamp,
					}, "OK"
				else
					return nil, "InvalidDistance"
				end
			else
				return nil, "SnapshotStale"
			end
		else
			return nil, "InvalidSnapshot"
		end
	end
	return nil, "InvalidCandidate"
end

function MultiThreatAnalysis.new(dependencies)
	assert(type(dependencies) == "table", "MultiThreatAnalysis requires dependencies")

	local config = dependencies.config
	local targetDiscovery = dependencies.targetDiscovery
	local physicsObserver = dependencies.physicsObserver
	local velocityEstimator = dependencies.velocityEstimator
	local recoveryAnalysis = dependencies.recoveryAnalysis

	assert(type(config) == "table", "MultiThreatAnalysis requires validated config")

	local configOk, configSnapshot = pcall(snapshotConfig, config)
	assert(configOk, "MultiThreatAnalysis could not read config")
	assert(configSnapshot.targetMode == "Player" or configSnapshot.targetMode == "NPC", "targetMode must be Player or NPC")
	assert(hasMethods(targetDiscovery, { "GetCandidates", "IsCandidateCurrent" }), "MultiThreatAnalysis requires a compatible TargetDiscovery")
	assert(hasMethods(physicsObserver, { "ObservePosition" }), "MultiThreatAnalysis requires a compatible PhysicsObserver")
	assert(hasMethods(velocityEstimator, { "Update", "GetEstimate", "Reset" }), "MultiThreatAnalysis requires a compatible VelocityEstimator")
	assert(recoveryAnalysis == nil or hasMethods(recoveryAnalysis, { "Record" }), "recoveryAnalysis must be nil or provide Record")
	assert(isFiniteNumber(configSnapshot.maxThreatCandidates) and configSnapshot.maxThreatCandidates % 1 == 0 and configSnapshot.maxThreatCandidates >= 1 and configSnapshot.maxThreatCandidates <= 64, "maxThreatCandidates must be an integer from 1 to 64")
	assert(isFiniteNumber(configSnapshot.maxThreatResults) and configSnapshot.maxThreatResults % 1 == 0 and configSnapshot.maxThreatResults >= 1 and configSnapshot.maxThreatResults <= configSnapshot.maxThreatCandidates, "maxThreatResults must be an integer from 1 to maxThreatCandidates")
	assert(isFiniteNumber(configSnapshot.threatAnalysisMinInterval) and configSnapshot.threatAnalysisMinInterval > 0, "threatAnalysisMinInterval must be finite and positive")
	assert(isFiniteNumber(configSnapshot.threatMaxEstimateAge) and configSnapshot.threatMaxEstimateAge > 0, "threatMaxEstimateAge must be finite and positive")
	assert(isFiniteNumber(configSnapshot.threatPredictionHorizon) and configSnapshot.threatPredictionHorizon > 0, "threatPredictionHorizon must be finite and positive")
	assert(isFiniteNumber(configSnapshot.threatNearDistance) and configSnapshot.threatNearDistance > 0, "threatNearDistance must be finite and positive")
	assert(isFiniteNumber(configSnapshot.threatCriticalDistance) and configSnapshot.threatCriticalDistance >= 0 and configSnapshot.threatCriticalDistance < configSnapshot.threatNearDistance, "threatCriticalDistance must be non-negative and less than threatNearDistance")
	assert(isFiniteNumber(configSnapshot.threatMaxApproachSpeed) and configSnapshot.threatMaxApproachSpeed > 0, "threatMaxApproachSpeed must be finite and positive")

	return setmetatable({
		Config = configSnapshot,
		TargetDiscovery = targetDiscovery,
		PhysicsObserver = physicsObserver,
		VelocityEstimator = velocityEstimator,
		RecoveryAnalysis = recoveryAnalysis,
		_nextStartIndex = {
			Player = 1,
			NPC = 1,
		},
		_lastAnalysisAt = nil,
		_destroyed = false,
	}, MultiThreatAnalysis)
end

function MultiThreatAnalysis:_record(reason, value)
	local recoveryAnalysis = self.RecoveryAnalysis
	if recoveryAnalysis then
		local success, recorded = pcall(function()
			return recoveryAnalysis:Record("ThreatAnalysis", reason, value)
		end)
		return success and recorded == true
	end
	return false
end

function MultiThreatAnalysis:_resetEstimate(model)
	if isModel(model) then
		local success, result = pcall(function()
			return self.VelocityEstimator:Reset(model)
		end)
		return success and result == true
	end
	return false
end

function MultiThreatAnalysis:_observeCandidate(candidate, mode)
	local currentOk, isCurrent = pcall(function()
		return self.TargetDiscovery:IsCandidateCurrent(candidate, mode)
	end)

	if currentOk and isCurrent == true then
		local snapshotOk, snapshot = pcall(function()
			return self.PhysicsObserver:ObservePosition(candidate.model)
		end)

		if snapshotOk
			and type(snapshot) == "table"
			and snapshot.model == candidate.model
			and isFiniteVector3(snapshot.position)
			and isFiniteNumber(snapshot.timestamp) then

			local estimateOk, estimate = pcall(function()
				return self.VelocityEstimator:Update(snapshot)
			end)

			if not estimateOk then
				estimate = nil
			end

			if not estimate then
				local getOk, previousEstimate = pcall(function()
					return self.VelocityEstimator:GetEstimate(candidate.model)
				end)
				if getOk then
					estimate = previousEstimate
				end
			end

			return {
				snapshot = snapshot,
				estimate = estimate,
			}, "OK"
		else
			return nil, "InvalidCandidateSnapshot"
		end
	end

	return nil, "CandidateUnavailable"
end

function MultiThreatAnalysis:Analyze(localRecord)
	if not self._destroyed then
		local config = self.Config

		if config.multiThreatAnalysisEnabled == true then
			local localSnapshot = type(localRecord) == "table" and localRecord.snapshot or nil

			if type(localSnapshot) == "table"
				and isModel(localSnapshot.model)
				and isFiniteVector3(localSnapshot.position)
				and isFiniteNumber(localSnapshot.timestamp)
				and localRecord.model == localSnapshot.model then

				local now = os.clock()
				local localSnapshotAge = now - localSnapshot.timestamp

				if isFiniteNumber(localSnapshotAge)
					and localSnapshotAge >= 0
					and localSnapshotAge <= config.threatMaxEstimateAge then

					if not self._lastAnalysisAt
						or now - self._lastAnalysisAt >= config.threatAnalysisMinInterval then

						self._lastAnalysisAt = now

						local mode = config.targetMode
						local startIndex = self._nextStartIndex[mode] or 1

						local discoveryOk, candidates, discoveryStatus, inspectedCount, sourceCount, rotationWindowCount = pcall(function()
							return self.TargetDiscovery:GetCandidates(
								mode,
								localSnapshot.position,
								config.maxThreatCandidates,
								startIndex
							)
						end)

						if discoveryOk then
							if discoveryStatus == "OK" and type(candidates) == "table" then
								inspectedCount = inspectedCount or #candidates
								sourceCount = sourceCount or inspectedCount
								rotationWindowCount = rotationWindowCount or sourceCount

								if isFiniteNumber(inspectedCount)
									and isFiniteNumber(sourceCount)
									and isFiniteNumber(rotationWindowCount)
									and inspectedCount >= 0
									and sourceCount >= 0
									and rotationWindowCount >= 0 then

									inspectedCount = math.floor(inspectedCount)
									sourceCount = math.floor(sourceCount)
									rotationWindowCount = math.floor(rotationWindowCount)

									if inspectedCount <= config.maxThreatCandidates
										and inspectedCount <= sourceCount
										and rotationWindowCount <= sourceCount then

										local candidateCount = #candidates

										if candidateCount <= config.maxThreatCandidates
											and candidateCount <= inspectedCount then

											if rotationWindowCount > 0 then
												self._nextStartIndex[mode] =
													((startIndex - 1 + math.max(inspectedCount, 1)) % rotationWindowCount) + 1
											else
												self._nextStartIndex[mode] = 1
											end

											-- Discovery may take time. Revalidate the local
											-- snapshot before starting candidate assessment.
											local discoveryNow = os.clock()
											local localAgeAtDiscovery = discoveryNow - localSnapshot.timestamp

											if not isFiniteNumber(localAgeAtDiscovery)
												or localAgeAtDiscovery < 0
												or localAgeAtDiscovery > config.threatMaxEstimateAge then
												return nil, "LocalSnapshotStale"
											end

											local results = {}
											local rejectedCount = 0
											local nearestDistance = nil

											for index = 1, candidateCount do
												local candidate = candidates[index]
												local observation = nil

												if type(candidate) == "table" and isModel(candidate.model) then
													local observationResult = self:_observeCandidate(candidate, mode)
													observation = observationResult
												end

												if observation then
													-- ObservePosition() and the estimator run before
													-- this clock read. Candidate timestamps therefore
													-- cannot appear future-dated merely because the
													-- analysis clock was captured before observation.
													local assessmentNow = os.clock()
													local localAgeAtAssessment =
														assessmentNow - localSnapshot.timestamp

													if not isFiniteNumber(localAgeAtAssessment)
														or localAgeAtAssessment < 0
														or localAgeAtAssessment > config.threatMaxEstimateAge then
														return nil, "LocalSnapshotStale"
													end

													-- Revalidate local velocity against the same
													-- post-observation clock used for this candidate.
													local localVelocity, localVelocityTimestamp = getFreshVelocity(
														type(localRecord) == "table" and localRecord.estimate or nil,
														localSnapshot.model,
														localSnapshot.timestamp,
														assessmentNow,
														config.threatMaxEstimateAge
													)

													local result = assessContact(
														localSnapshot.position,
														localVelocity,
														localVelocityTimestamp,
														candidate,
														observation.snapshot,
														observation.estimate,
														config,
														assessmentNow
													)

													if result then
														results[#results + 1] = result
														nearestDistance =
															nearestDistance
															and math.min(nearestDistance, result.distance)
															or result.distance
													else
														rejectedCount += 1
														self:_resetEstimate(candidate.model)
													end
												else
													rejectedCount += 1
													if type(candidate) == "table" then
														self:_resetEstimate(candidate.model)
													end
												end
											end

											table.sort(results, function(left, right)
												if left.score == right.score then
													return left.distance < right.distance
												end
												return left.score > right.score
											end)

											local analyzedCount = #results
											local returnedCount = math.min(
												analyzedCount,
												config.maxThreatResults
											)

											for index = analyzedCount, returnedCount + 1, -1 do
												results[index] = nil
											end

											local packet = {
												timestamp = os.clock(),
												targetMode = mode,
												inspectedSourceEntries = inspectedCount,
												sourceEntriesAvailable = sourceCount,
												discoveryWindowEntries = rotationWindowCount,
												uninspectedSourceEntries = math.max(sourceCount - inspectedCount, 0),
												uninspectedWithinDiscoveryWindow = math.max(rotationWindowCount - inspectedCount, 0),
												analyzedCount = analyzedCount,
												rejectedCount = rejectedCount,
												returnedCount = returnedCount,
												nearestDistance = nearestDistance,
												highestAssessment = results[1] and results[1].assessment or "None",
												results = results,
												velocityNote = "Velocity uses fresh position-derived estimates; raw AssemblyLinearVelocity is not used for remote candidates.",
												authorityNote = "Client-side observation only; not authoritative game state.",
											}

											self:_record("BatchCompleted", analyzedCount)
											return packet, "OK"
										else
											return nil, "CandidateLimitExceeded"
										end
									else
										return nil, "InconsistentDiscoveryCounts"
									end
								else
									return nil, "InvalidDiscoveryCounts"
								end
							else
								return nil, discoveryStatus or "InvalidDiscoveryResult"
							end
						else
							self:_record("DiscoveryFailed", 0)
							return nil, "DiscoveryFailed"
						end
					else
						return nil, "RateLimited"
					end
				else
					return nil, "LocalSnapshotStale"
				end
			else
				return nil, "LocalSnapshotUnavailable"
			end
		else
			return nil, "Disabled"
		end
	end

	return nil, "Destroyed"
end

function MultiThreatAnalysis:Destroy()
	if not self._destroyed then
		self._destroyed = true
		self._nextStartIndex.Player = 1
		self._nextStartIndex.NPC = 1
		self._lastAnalysisAt = nil
		self.RecoveryAnalysis = nil
	end
end

return MultiThreatAnalysis
