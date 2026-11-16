-- Navigation Architecture v2.2
-- Foundation K: UncertaintyMap
-- Bounded, session-only grid of observation uncertainty. No world scanning or raycasts.

local UncertaintyMap = {}
UncertaintyMap.__index = UncertaintyMap

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

local function makeKey(gridX, gridZ)
    return tostring(gridX) .. ":" .. tostring(gridZ)
end

function UncertaintyMap.new(config)
    assert(type(config) == "table", "UncertaintyMap requires validated config")
    assert(isFiniteNumber(config.uncertaintyCellSize) and config.uncertaintyCellSize >= 4,
        "uncertaintyCellSize must be finite and >= 4")
    assert(isFiniteNumber(config.maxUncertaintyCells) and config.maxUncertaintyCells % 1 == 0
        and config.maxUncertaintyCells >= 1 and config.maxUncertaintyCells <= 256,
        "maxUncertaintyCells must be an integer from 1 to 256")
    assert(isFiniteNumber(config.uncertaintyMaxAge) and config.uncertaintyMaxAge > 0,
        "uncertaintyMaxAge must be finite and positive")

    return setmetatable({
        Config = config,
        _cells = {},
        _count = 0,
        _destroyed = false,
    }, UncertaintyMap)
end

-- Records an uncertainty estimate for a horizontal grid cell. This is not an
-- occupancy map: it does not claim a cell is blocked or safe.
function UncertaintyMap:Observe(position, uncertainty, reason, observedAt)
    if self._destroyed then
        return false, "Destroyed"
    end
    if not self.Config.evidenceLedgerEnabled then
        return false, "Disabled"
    end
    if not isFiniteVector3(position) then
        return false, "InvalidPosition"
    end
    if not isFiniteNumber(uncertainty) or uncertainty < 0 or uncertainty > 1 then
        return false, "InvalidUncertainty"
    end
    if type(reason) ~= "string" or #reason < 1 or #reason > 96 then
        return false, "InvalidReason"
    end

    local timestamp = observedAt or os.clock()
    if not isFiniteNumber(timestamp) or timestamp > os.clock() + 1 then
        return false, "InvalidTimestamp"
    end

    local gridX = math.floor(position.X / self.Config.uncertaintyCellSize)
    local gridZ = math.floor(position.Z / self.Config.uncertaintyCellSize)
    local key = makeKey(gridX, gridZ)
    local cell = self._cells[key]

    if cell then
        cell.uncertainty = cell.uncertainty * 0.65 + uncertainty * 0.35
        cell.observations = math.min(cell.observations + 1, 2147483647)
        cell.reason = reason
        cell.timestamp = timestamp
        return true, "Updated", key
    end

    if self._count >= self.Config.maxUncertaintyCells then
        local oldestKey = nil
        local oldestTimestamp = math.huge
        for existingKey, existingCell in pairs(self._cells) do
            if existingCell.timestamp < oldestTimestamp then
                oldestTimestamp = existingCell.timestamp
                oldestKey = existingKey
            end
        end
        if oldestKey then
            self._cells[oldestKey] = nil
            self._count -= 1
        end
    end

    self._cells[key] = {
        key = key,
        gridX = gridX,
        gridZ = gridZ,
        centerX = (gridX + 0.5) * self.Config.uncertaintyCellSize,
        centerZ = (gridZ + 0.5) * self.Config.uncertaintyCellSize,
        uncertainty = uncertainty,
        observations = 1,
        reason = reason,
        timestamp = timestamp,
    }
    self._count = math.min(self._count + 1, self.Config.maxUncertaintyCells)
    return true, "Recorded", key
end

function UncertaintyMap:GetAt(position, now)
    if self._destroyed then
        return nil, "Destroyed"
    end
    if not self.Config.evidenceLedgerEnabled then
        return nil, "Disabled"
    end
    if not isFiniteVector3(position) then
        return nil, "InvalidPosition"
    end
    local gridX = math.floor(position.X / self.Config.uncertaintyCellSize)
    local gridZ = math.floor(position.Z / self.Config.uncertaintyCellSize)
    local cell = self._cells[makeKey(gridX, gridZ)]
    if not cell then
        return nil, "UnknownCell"
    end
    local age = (now or os.clock()) - cell.timestamp
    if not isFiniteNumber(age) or age < 0 then
        return nil, "InvalidTimestamp"
    end
    if age > self.Config.uncertaintyMaxAge then
        return nil, "StaleCell"
    end
    return {
        key = cell.key,
        gridX = cell.gridX,
        gridZ = cell.gridZ,
        centerX = cell.centerX,
        centerZ = cell.centerZ,
        uncertainty = cell.uncertainty,
        observations = cell.observations,
        reason = cell.reason,
        timestamp = cell.timestamp,
        age = age,
    }, "OK"
end

function UncertaintyMap:GetCells(limit, now)
    if self._destroyed then
        return {}, "Destroyed"
    end
    if not self.Config.evidenceLedgerEnabled then
        return {}, "Disabled"
    end

    local requested = limit or self.Config.maxUncertaintyCells
    if not isFiniteNumber(requested) or requested % 1 ~= 0 or requested < 0 then
        return {}, "InvalidLimit"
    end
    local currentTime = now or os.clock()
    if not isFiniteNumber(currentTime) then
        return {}, "InvalidTimestamp"
    end

    local result = {}
    for _, cell in pairs(self._cells) do
        local age = currentTime - cell.timestamp
        if age >= 0 and age <= self.Config.uncertaintyMaxAge then
            result[#result + 1] = {
                key = cell.key,
                gridX = cell.gridX,
                gridZ = cell.gridZ,
                centerX = cell.centerX,
                centerZ = cell.centerZ,
                uncertainty = cell.uncertainty,
                observations = cell.observations,
                reason = cell.reason,
                timestamp = cell.timestamp,
                age = age,
            }
        end
    end
    table.sort(result, function(a, b)
        if a.timestamp == b.timestamp then
            return a.key < b.key
        end
        return a.timestamp > b.timestamp
    end)
    local keepCount = math.min(requested, self.Config.maxUncertaintyCells)
    for index = #result, keepCount + 1, -1 do
        result[index] = nil
    end
    return result, "OK"
end

function UncertaintyMap:GetSummary()
    if self._destroyed then
        return nil, "Destroyed"
    end
    return {
        storedCells = self._count,
        capacity = self.Config.maxUncertaintyCells,
        cellSize = self.Config.uncertaintyCellSize,
        isOccupancyMap = false,
    }, "OK"
end

function UncertaintyMap:Reset()
    if self._destroyed then
        return false, "Destroyed"
    end
    table.clear(self._cells)
    self._count = 0
    return true, "Reset"
end

function UncertaintyMap:Destroy()
    if self._destroyed then
        return
    end
    table.clear(self._cells)
    self._count = 0
    self._destroyed = true
end

return UncertaintyMap
