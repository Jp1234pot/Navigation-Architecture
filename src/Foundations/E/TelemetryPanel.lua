
-- Navigation Architecture v2.2
-- Module: TelemetryPanel
-- Client-only, read-only presentation for SamplingCoordinator packets.
-- Creates and destroys only the ScreenGui instance owned by this module.

local TelemetryPanel = {}
TelemetryPanel.__index = TelemetryPanel

local PANEL_NAME = "NavigationV22TelemetryPanel"
local PANEL_SIZE = UDim2.fromOffset(330, 270)

local COLORS = {
    panel = Color3.fromRGB(18, 20, 27),
    header = Color3.fromRGB(35, 39, 50),
    border = Color3.fromRGB(78, 86, 105),
    primary = Color3.fromRGB(232, 236, 244),
    secondary = Color3.fromRGB(160, 171, 190),
    good = Color3.fromRGB(133, 214, 164),
    warning = Color3.fromRGB(242, 197, 112),
}

local function safeName(instance)
    if not instance then
        return "Unavailable"
    end
    local success, name = pcall(function()
        return instance.Name
    end)
    return success and tostring(name) or "Unavailable"
end

local function formatVector3(value)
    if typeof(value) ~= "Vector3" then
        return "n/a"
    end
    return string.format("%.1f, %.1f, %.1f", value.X, value.Y, value.Z)
end

local function formatEstimate(estimate, field)
    if type(estimate) ~= "table" then
        return "n/a"
    end
    return formatVector3(estimate[field])
end

local function buildLocalLines(record)
    if type(record) ~= "table" then
        return {
            "Status: unavailable",
            "Position: n/a",
            "Velocity: n/a",
            "Acceleration: n/a",
            "Humanoid: n/a | Anchored: n/a",
        }
    end

    local snapshot = record.snapshot
    local estimate = record.estimate
    if not snapshot then
        return {
            "Status: " .. tostring(record.observeStatus or "Unavailable"),
            "Position: n/a",
            "Velocity: n/a (" .. tostring(record.estimateStatus or "NotSampled") .. ")",
            "Acceleration: n/a",
            "Humanoid: n/a | Anchored: n/a",
        }
    end

    local humanoidState = snapshot.humanoidState
    local stateName = typeof(humanoidState) == "EnumItem" and humanoidState.Name or tostring(humanoidState or "Unknown")
    local rootAnchored = snapshot.rootAnchored == true
    local assemblyAnchored = snapshot.assemblyRootAnchored == true
    local speed = type(estimate) == "table" and estimate.speed or nil

    return {
        "Status: " .. tostring(record.observeStatus) .. " | " .. tostring(record.estimateStatus),
        "Position: " .. formatVector3(snapshot.position),
        "Velocity: " .. formatEstimate(estimate, "velocity") .. " studs/s",
        "Acceleration: " .. formatEstimate(estimate, "acceleration") .. " studs/s^2",
        string.format("Speed: %s | State: %s", speed and string.format("%.1f", speed) or "n/a", stateName),
        string.format("Anchored: root=%s assembly=%s", tostring(rootAnchored), tostring(assemblyAnchored)),
        "Move direction: " .. formatVector3(snapshot.moveDirection),
    }
end

local function buildTargetLines(record, targetStatus)
    if type(record) ~= "table" then
        return {
            "Target: none selected",
            "Status: " .. tostring(targetStatus or "NoTarget"),
            "Position: n/a",
            "Velocity: n/a",
        }
    end

    local candidate = record.candidate
    local label = candidate and candidate.player and safeName(candidate.player)
        or safeName(record.model)
    local kind = candidate and candidate.kind or "Target"

    if not record.snapshot then
        return {
            string.format("Target: %s (%s)", label, kind),
            "Status: " .. tostring(record.validationStatus or record.observeStatus or targetStatus),
            "Position: unavailable locally",
            "Velocity: n/a",
        }
    end

    return {
        string.format("Target: %s (%s)", label, kind),
        "Status: " .. tostring(record.observeStatus) .. " | " .. tostring(record.estimateStatus),
        "Position: " .. formatVector3(record.snapshot.position),
        "Velocity: " .. formatEstimate(record.estimate, "velocity") .. " studs/s",
    }
end

local function makeLabel(parent, name, position, size, text, textSize, color)
    local label = Instance.new("TextLabel")
    label.Name = name
    label.BackgroundTransparency = 1
    label.BorderSizePixel = 0
    label.Position = position
    label.Size = size
    label.Font = Enum.Font.Code
    label.Text = text
    label.TextColor3 = color
    label.TextSize = textSize
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextYAlignment = Enum.TextYAlignment.Center
    label.TextWrapped = false
    label.TextTruncate = Enum.TextTruncate.AtEnd
    label.RichText = false
    label.Parent = parent
    return label
end

function TelemetryPanel.new(player, enabled)
    assert(player and player:IsA("Player"), "TelemetryPanel requires LocalPlayer")

    local self = setmetatable({
        Player = player,
        Enabled = enabled ~= false,
        Destroyed = false,
        ScreenGui = nil,
        Root = nil,
        Body = nil,
        Status = nil,
    }, TelemetryPanel)

    if not self.Enabled then
        return self
    end

    local playerGui = player:FindFirstChildOfClass("PlayerGui")
        or player:WaitForChild("PlayerGui", 10)
    assert(playerGui and playerGui:IsA("PlayerGui"), "TelemetryPanel could not access PlayerGui")

    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = PANEL_NAME
    screenGui.ResetOnSpawn = false
    screenGui.IgnoreGuiInset = false
    screenGui.DisplayOrder = 5
    screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

    local root = Instance.new("Frame")
    root.Name = "Panel"
    root.AnchorPoint = Vector2.new(0, 0)
    root.Position = UDim2.fromOffset(12, 12)
    root.Size = PANEL_SIZE
    root.BackgroundColor3 = COLORS.panel
    root.BackgroundTransparency = 0.12
    root.BorderSizePixel = 0
    root.ClipsDescendants = true
    root.Parent = screenGui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 7)
    corner.Parent = root

    local stroke = Instance.new("UIStroke")
    stroke.Color = COLORS.border
    stroke.Transparency = 0.25
    stroke.Thickness = 1
    stroke.Parent = root

    local header = Instance.new("Frame")
    header.Name = "Header"
    header.Size = UDim2.new(1, 0, 0, 29)
    header.BackgroundColor3 = COLORS.header
    header.BorderSizePixel = 0
    header.Parent = root

    makeLabel(header, "Title", UDim2.fromOffset(10, 0), UDim2.new(1, -20, 1, 0),
        "NAVIGATION  /  TELEMETRY", 13, COLORS.primary)

    local status = makeLabel(root, "Status", UDim2.fromOffset(10, 34), UDim2.new(1, -20, 0, 17),
        "WAITING FOR FIRST SAMPLE", 11, COLORS.warning)

    local body = makeLabel(root, "Readout", UDim2.fromOffset(10, 54), UDim2.new(1, -20, 1, -80),
        "LOCAL CHARACTER\nWaiting for telemetry...\n\nSELECTED TARGET\nNo target selected", 11, COLORS.primary)
    body.TextYAlignment = Enum.TextYAlignment.Top
    body.TextWrapped = true
    body.TextTruncate = Enum.TextTruncate.None

    local footer = makeLabel(root, "Footer", UDim2.new(0, 10, 1, -17), UDim2.new(1, -20, 0, 13),
        "CLIENT OBSERVATION ONLY  |  NOT SERVER-AUTHORITATIVE", 9, COLORS.secondary)

    self.ScreenGui = screenGui
    self.Root = root
    self.Body = body
    self.Status = status
    screenGui.Parent = playerGui

    return self
end

function TelemetryPanel:Update(packet)
    if self.Destroyed or not self.Enabled or not self.Body or type(packet) ~= "table" then
        return false
    end

    local localRecord = packet.localCharacter
    local targetRecord = packet.target
    local lines = { "LOCAL CHARACTER" }

    for _, line in ipairs(buildLocalLines(localRecord)) do
        table.insert(lines, line)
    end

    table.insert(lines, "")
    table.insert(lines, "SELECTED TARGET")
    for _, line in ipairs(buildTargetLines(targetRecord, packet.targetStatus)) do
        table.insert(lines, line)
    end

    self.Body.Text = table.concat(lines, "\n")

    local localOk = localRecord and localRecord.snapshot ~= nil
    self.Status.Text = string.format("SAMPLE %s  |  %.2f s CADENCE",
        localOk and "ACTIVE" or tostring(packet.status or "WAITING"),
        tonumber(packet.sampleInterval) or 0)
    self.Status.TextColor3 = localOk and COLORS.good or COLORS.warning

    return true
end

function TelemetryPanel:SetVisible(visible)
    if self.Destroyed or not self.Root then
        return false
    end
    self.Root.Visible = visible == true
    return true
end

function TelemetryPanel:Destroy()
    if self.Destroyed then
        return
    end
    self.Destroyed = true

    -- Destroy only the ScreenGui instance created by this module.
    if self.ScreenGui then
        self.ScreenGui:Destroy()
    end

    self.ScreenGui = nil
    self.Root = nil
    self.Body = nil
    self.Status = nil
    self.Player = nil
end

return TelemetryPanel
