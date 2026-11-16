
-- Navigation Architecture v2.2
-- Module: VelocityEstimator
-- Client-only, position-derived velocity and acceleration estimates.
-- This module does not write to Instances or create sampling connections.

local VelocityEstimator = {}
VelocityEstimator.__index = VelocityEstimator

local function isFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function isFiniteVector3(value)
    return typeof(value) == "Vector3"
        and isFiniteNumber(value.X)
        and isFiniteNumber(value.Y)
        and isFiniteNumber(value.Z)
end

local function isModel(value)
    if typeof(value) ~= "Instance" then
        return false
    end

    local success, result = pcall(function()
        return value:IsA("Model")
    end)

    return success and result == true
end

local function copyEstimate(estimate)
    if not estimate then
        return nil
    end

    local result = {}
    for key, value in pairs(estimate) do
        result[key] = value
    end
    return result
end

function VelocityEstimator.new(config)
    config = config or {}

    local alpha = config.velocitySmoothingAlpha or 0.35
    local minDelta = config.minVelocitySampleDelta or (1 / 240)
    local maxGap = config.maxVelocitySampleGap or 1.0

    assert(isFiniteNumber(alpha) and alpha > 0 and alpha <= 1,
        "velocitySmoothingAlpha must be in (0, 1]")
    assert(isFiniteNumber(minDelta) and minDelta > 0,
        "minVelocitySampleDelta must be positive")
    assert(isFiniteNumber(maxGap) and maxGap > minDelta,
        "maxVelocitySampleGap must exceed minVelocitySampleDelta")

    return setmetatable({
        Alpha = alpha,
        MinSampleDelta = minDelta,
        MaxSampleGap = maxGap,
        _samples = setmetatable({}, { __mode = "k" }),
        _destroyed = false,
    }, VelocityEstimator)
end

function VelocityEstimator:Update(snapshot)
    if self._destroyed then
        return nil, "Destroyed"
    end

    if type(snapshot) ~= "table"
        or not isModel(snapshot.model)
        or not isFiniteVector3(snapshot.position) then
        return nil, "InvalidSnapshot"
    end

    if not isFiniteNumber(snapshot.timestamp) then
        return nil, "InvalidTimestamp"
    end

    local model = snapshot.model
    local position = snapshot.position
    local timestamp = snapshot.timestamp
    local previous = self._samples[model]

    if not previous then
        self._samples[model] = {
            position = position,
            timestamp = timestamp,
            velocity = nil,
            acceleration = nil,
            sampleCount = 1,
            estimate = nil,
        }

        return nil, "WarmingUp"
    end

    local deltaTime = timestamp - previous.timestamp

    if not isFiniteNumber(deltaTime) or deltaTime <= 0 then
        return nil, "InvalidTimestamp"
    end

    if deltaTime < self.MinSampleDelta then
        return copyEstimate(previous.estimate), "SampleIntervalTooSmall"
    end

    if deltaTime > self.MaxSampleGap then
        self._samples[model] = {
            position = position,
            timestamp = timestamp,
            velocity = nil,
            acceleration = nil,
            sampleCount = 1,
            estimate = nil,
        }

        return nil, "SampleGapReset"
    end

    local rawVelocity = (position - previous.position) / deltaTime

    if not isFiniteVector3(rawVelocity) then
        return copyEstimate(previous.estimate), "NonFiniteVelocity"
    end

    local smoothedVelocity
    if previous.velocity then
        smoothedVelocity = previous.velocity:Lerp(
            rawVelocity,
            self.Alpha
        )
    else
        smoothedVelocity = rawVelocity
    end

    if not isFiniteVector3(smoothedVelocity) then
        return copyEstimate(previous.estimate), "NonFiniteVelocity"
    end

    local acceleration = nil
    local hasAcceleration = false

    if previous.velocity then
        acceleration = (smoothedVelocity - previous.velocity) / deltaTime

        if not isFiniteVector3(acceleration) then
            return copyEstimate(previous.estimate), "NonFiniteAcceleration"
        end

        hasAcceleration = true
    end

    local sampleCount = previous.sampleCount + 1

    local estimate = {
        model = model,
        timestamp = timestamp,
        position = position,
        velocity = smoothedVelocity,
        acceleration = acceleration,
        speed = smoothedVelocity.Magnitude,
        hasAcceleration = hasAcceleration,
        sampleCount = sampleCount,
        sampleDelta = deltaTime,
        source = "PositionDelta",
    }

    self._samples[model] = {
        position = position,
        timestamp = timestamp,
        velocity = smoothedVelocity,
        acceleration = acceleration,
        sampleCount = sampleCount,
        estimate = estimate,
    }

    return copyEstimate(estimate), "OK"
end

function VelocityEstimator:GetEstimate(model)
    if self._destroyed or not isModel(model) then
        return nil
    end

    local sample = self._samples[model]
    if not sample then
        return nil
    end

    return copyEstimate(sample.estimate)
end

function VelocityEstimator:Reset(model)
    if self._destroyed then
        return false, "Destroyed"
    end

    if model == nil then
        self._samples = setmetatable({}, { __mode = "k" })
        return true, "AllSamplesReset"
    end

    if not isModel(model) then
        return false, "InvalidModel"
    end

    self._samples[model] = nil
    return true, "ModelSampleReset"
end

function VelocityEstimator:Destroy()
    if self._destroyed then
        return
    end

    self._samples = setmetatable({}, { __mode = "k" })
    self._destroyed = true
end

return VelocityEstimator
