
-- Navigation Architecture v2.2
-- Foundation A: StateManager
-- Reconstructed implementation.
-- Compatible with the documented Foundation D/H interface.

local StateManager = {}
StateManager.__index = StateManager

StateManager.States = table.freeze({
    Idle = "Idle",
    Scanning = "Scanning",
    Traversal = "Traversal",
    Reached = "Reached",
    Failed = "Failed",
    Dead = "Dead",
})

local VALID_STATES = {}

for _, stateName in pairs(StateManager.States) do
    VALID_STATES[stateName] = true
end

function StateManager.new(initialState)
    initialState = initialState or StateManager.States.Idle

    assert(
        VALID_STATES[initialState],
        "StateManager received an invalid initial state"
    )

    local self = setmetatable({}, StateManager)

    self._state = initialState
    self._lastReason = "Initialized"
    self._destroyed = false

    return self
end

function StateManager:GetState()
    if self._destroyed then
        return nil
    end

    return self._state
end

function StateManager:GetLastReason()
    if self._destroyed then
        return nil
    end

    return self._lastReason
end

function StateManager:SetState(newState, reason)
    if self._destroyed then
        return false, nil
    end

    assert(
        VALID_STATES[newState],
        "StateManager received an invalid state"
    )

    local previousState = self._state

    if previousState == newState then
        if reason ~= nil then
            self._lastReason = tostring(reason)
        end

        return false, previousState
    end

    self._state = newState
    self._lastReason = tostring(reason or "Unspecified")

    return true, previousState
end

function StateManager:Destroy()
    if self._destroyed then
        return
    end

    self._destroyed = true
    self._state = nil
    self._lastReason = nil
end

return StateManager
