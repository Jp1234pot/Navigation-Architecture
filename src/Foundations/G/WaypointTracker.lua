
-- Navigation Architecture v2.2
-- Module: WaypointTracker
-- Foundation G: bounded, still read-only waypoint progress tracking.

local WaypointTracker = {}
WaypointTracker.__index = WaypointTracker

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

local function copyWaypoint(waypoint)
    return {
        index = waypoint.index,
        position = waypoint.position,
        action = waypoint.action,
        label = waypoint.label,
    }
end

local function copyProgress(progress)
    if not progress then
        return nil
    end

    local result = {}

    for key, value in pairs(progress) do
        if key == "waypoints" then
            local copied = {}

            for index, waypoint in ipairs(value) do
                copied[index] = copyWaypoint(waypoint)
            end

            result.waypoints = copied
        else
            result[key] = value
        end
    end

    return result
end

function WaypointTracker.new(config)
    assert(type(config) == "table", "WaypointTracker requires validated config")

    return setmetatable({
        Config = config,
        _waypoints = {},
        _requestId = nil,
        _currentIndex = 1,
        _lastPosition = nil,
        _status = "Idle",
        _reason = nil,
        _destroyed = false,
    }, WaypointTracker)
end

function WaypointTracker:SetPath(pathPacket)
    if self._destroyed then
        return false, "Destroyed"
    end

    if type(pathPacket) ~= "table" then
        return false, "InvalidPathPacket"
    end

    if pathPacket.status ~= "Success" then
        return false, "PathNotSuccessful"
    end

    if type(pathPacket.waypoints) ~= "table" then
        return false, "InvalidWaypoints"
    end

    local waypointCount = #pathPacket.waypoints
    local maximum = self.Config.maxTrackedWaypoints or 512

    if waypointCount == 0 then
        return false, "EmptyWaypoints"
    end

    if waypointCount > maximum then
        return false, "WaypointLimitExceeded"
    end

    local copied = {}

    for index, waypoint in ipairs(pathPacket.waypoints) do
        if type(waypoint) ~= "table"
            or not isFiniteVector3(waypoint.position) then
            return false, "InvalidWaypoint"
        end

        copied[index] = {
            index = index,
            position = waypoint.position,
            action = waypoint.action,
            label = waypoint.label,
        }
    end

    self._waypoints = copied
    self._requestId = pathPacket.requestId
    self._currentIndex = 1
    self._lastPosition = nil
    self._status = "Tracking"
    self._reason = nil

    return true, "Accepted"
end

function WaypointTracker:Update(position)
    if self._destroyed then
        return nil, "Destroyed"
    end

    if self._status ~= "Tracking" then
        return nil, "NotTracking"
    end

    if not isFiniteVector3(position) then
        return nil, "InvalidPosition"
    end

    self._lastPosition = position

    local advances = 0
    local maximumAdvances =
        self.Config.maxWaypointAdvancesPerUpdate or 4

    while self._currentIndex <= #self._waypoints
        and advances < maximumAdvances do

        local waypoint = self._waypoints[self._currentIndex]
        local difference = position - waypoint.position

        local reachedDistance =
            self.Config.waypointReachedDistance or 2.75

        -- Climb is a PathWaypoint label, not a PathWaypointAction enum.
        if waypoint.label == "Climb" then
            reachedDistance =
                self.Config.climbWaypointReachedDistance or 3.5
        end

        local verticalLimit =
            self.Config.maxWaypointVerticalError or 5.0

        if difference.Magnitude > reachedDistance
            or math.abs(difference.Y) > verticalLimit then
            break
        end

        self._currentIndex += 1
        advances += 1
    end

    if self._currentIndex > #self._waypoints then
        self._status = "Completed"
        self._reason = "AllWaypointsReached"
    end

    return self:GetProgress(), "OK"
end

function WaypointTracker:GetProgress()
    if self._destroyed then
        return nil
    end

    local total = #self._waypoints
    local completed = math.min(self._currentIndex - 1, total)

    local progress = {
        requestId = self._requestId,
        status = self._status,
        reason = self._reason,
        currentIndex = self._currentIndex,
        totalWaypoints = total,
        completedWaypoints = completed,
        remainingWaypoints = math.max(0, total - completed),
        progress = total > 0 and completed / total or 0,
        lastPosition = self._lastPosition,
        waypoints = self._waypoints,
    }

    return copyProgress(progress)
end

function WaypointTracker:Reset(reason)
    if self._destroyed then
        return false, "Destroyed"
    end

    self._waypoints = {}
    self._requestId = nil
    self._currentIndex = 1
    self._lastPosition = nil
    self._status = "Idle"
    self._reason = reason or "Reset"

    return true, "Reset"
end

function WaypointTracker:Destroy()
    if self._destroyed then
        return
    end

    self._destroyed = true
    self._waypoints = {}
    self._requestId = nil
    self._currentIndex = 1
    self._lastPosition = nil
    self._status = "Destroyed"
    self._reason = nil
end

return WaypointTracker
