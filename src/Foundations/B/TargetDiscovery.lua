
-- Navigation Architecture v2.2
-- Module: TargetDiscovery
-- Based on recovered original source.
-- Read-only target enumeration. Does not move, highlight, modify, or control targets.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local TargetDiscovery = {}
TargetDiscovery.__index = TargetDiscovery

local function getHumanoid(model)
    if not model or not model:IsA("Model") then
        return nil
    end
    return model:FindFirstChildOfClass("Humanoid")
end

local function getRoot(model)
    if not model or not model:IsA("Model") then
        return nil
    end

    local root = model:FindFirstChild("HumanoidRootPart")
    if root and root:IsA("BasePart") then
        return root
    end

    local primaryPart = model.PrimaryPart
    if primaryPart and primaryPart:IsA("BasePart") then
        return primaryPart
    end

    return nil
end

local function isAliveAndPresent(model)
    if not model or not model:IsA("Model") then
        return false
    end

    local success, result = pcall(function()
        local humanoid = getHumanoid(model)
        local root = getRoot(model)
        return humanoid ~= nil
            and root ~= nil
            and humanoid.Health > 0
            and model:IsDescendantOf(Workspace)
    end)

    return success and result == true
end

function TargetDiscovery.new(localPlayer, config, factionValidator)
    assert(localPlayer and localPlayer:IsA("Player"), "TargetDiscovery requires the LocalPlayer")
    assert(type(config) == "table", "TargetDiscovery requires a config table")
    assert(factionValidator ~= nil, "TargetDiscovery requires a FactionValidator")

    return setmetatable({
        LocalPlayer = localPlayer,
        Config = config,
        FactionValidator = factionValidator,
    }, TargetDiscovery)
end

function TargetDiscovery:_getNPCFolder()
    local folderName = self.Config.npcFolderName
    if type(folderName) ~= "string" or folderName == "" then
        return nil
    end

    local folder = Workspace:FindFirstChild(folderName)
    if folder and folder:IsA("Folder") then
        return folder
    end

    return nil
end

function TargetDiscovery:_isValidNPC(model)
    if not model or not model:IsA("Model") then
        return false
    end

    local npcFolder = self:_getNPCFolder()
    if not npcFolder or model.Parent ~= npcFolder then
        return false
    end

    -- Never classify a connected player's character as an NPC.
    if Players:GetPlayerFromCharacter(model) ~= nil then
        return false
    end

    if self.Config.npcTargetAttribute then
        local success, isTargetable = pcall(function()
            return model:GetAttribute(self.Config.npcTargetAttribute)
        end)

        if not success or isTargetable ~= true then
            return false
        end
    end

    return true
end

function TargetDiscovery:_buildCandidate(model, player, kind, originPosition)
    if not isAliveAndPresent(model) then
        return nil
    end

    if player and player == self.LocalPlayer then
        return nil
    end

    if kind == "NPC" then
        if player ~= nil or not self:_isValidNPC(model) then
            return nil
        end
    end

    local eligible, classification, localSource, candidateSource =
        self.FactionValidator:IsEligible(self.LocalPlayer, player or model, kind)

    if not eligible then
        return nil
    end

    local humanoid = getHumanoid(model)
    local root = getRoot(model)

    if not humanoid or not root then
        return nil
    end

    local distance
    if typeof(originPosition) == "Vector3" then
        distance = (originPosition - root.Position).Magnitude
    end

    return {
        model = model,
        player = player,
        root = root,
        humanoid = humanoid,
        kind = kind,
        classification = classification,
        localFactionSource = localSource,
        candidateFactionSource = candidateSource,
        distance = distance,
    }
end

function TargetDiscovery:GetCandidates(targetMode, originPosition, maxCandidates, startIndex)
    local mode = targetMode or self.Config.targetMode

    if not self.Config.enabled then
        return {}, "Disabled"
    end

    if mode ~= "Player" and mode ~= "NPC" then
        return {}, "InvalidTargetMode"
    end

    if maxCandidates ~= nil then
        if type(maxCandidates) ~= "number" or maxCandidates ~= maxCandidates
            or maxCandidates % 1 ~= 0 or maxCandidates < 1 or maxCandidates > 2048 then
            return {}, "InvalidCandidateLimit", 0, 0
        end
    end

    if startIndex ~= nil then
        if type(startIndex) ~= "number" or startIndex ~= startIndex
            or startIndex == math.huge or startIndex == -math.huge
            or startIndex % 1 ~= 0 or startIndex < 1 then
            return {}, "InvalidStartIndex", 0, 0
        end
    end

    local candidates = {}

    if mode == "Player" then
        -- Player mode enumerates only Players:GetPlayers().
        local players = Players:GetPlayers()
        local sourceCount = #players
        local inspectCount = math.min(sourceCount, maxCandidates or sourceCount)
        local start = sourceCount > 0 and (((startIndex or 1) - 1) % sourceCount) + 1 or 1

        for offset = 0, inspectCount - 1 do
            local playerIndex = ((start + offset - 1) % sourceCount) + 1
            local targetPlayer = players[playerIndex]

            if targetPlayer and targetPlayer ~= self.LocalPlayer then
                local character = targetPlayer.Character
                local candidate = self:_buildCandidate(
                    character,
                    targetPlayer,
                    "Player",
                    originPosition
                )

                if candidate then
                    table.insert(candidates, candidate)
                end
            end
        end

        return candidates, "OK", inspectCount, sourceCount, sourceCount
    end

    -- NPC mode only examines direct Model children of Workspace.NPCs.
    -- No full-Workspace descendant scan fallback exists.
    local npcFolder = self:_getNPCFolder()

    if not npcFolder then
        return {}, "NPCFolderUnavailable"
    end

    local children = npcFolder:GetChildren()
    local totalChildCount = #children
    local sourceCount = math.min(
        totalChildCount,
        self.Config.maxNpcCandidatesToInspect
    )
    local inspectCount = math.min(sourceCount, maxCandidates or sourceCount)
    local start = sourceCount > 0 and (((startIndex or 1) - 1) % sourceCount) + 1 or 1

    for offset = 0, inspectCount - 1 do
        local childIndex = ((start + offset - 1) % sourceCount) + 1
        local instance = children[childIndex]

        if instance and instance:IsA("Model") then
            local candidate = self:_buildCandidate(
                instance,
                nil,
                "NPC",
                originPosition
            )

            if candidate then
                table.insert(candidates, candidate)
            end
        end
    end

    return candidates, "OK", inspectCount, totalChildCount, sourceCount
end

function TargetDiscovery:FindNearest(targetMode, originPosition)
    if typeof(originPosition) ~= "Vector3" then
        return nil, {}, "OriginPositionRequired"
    end

    local candidates, status = self:GetCandidates(targetMode, originPosition)
    local nearest = nil
    local shortestDistance = math.huge

    for _, candidate in ipairs(candidates) do
        local distance = candidate.distance

        if distance and distance < shortestDistance then
            shortestDistance = distance
            nearest = candidate
        end
    end

    return nearest, candidates, status
end

function TargetDiscovery:IsCandidateCurrent(candidate, targetMode)
    if type(candidate) ~= "table" or not candidate.model then
        return false, "InvalidCandidate"
    end

    local mode = targetMode or self.Config.targetMode

    if not self.Config.enabled then
        return false, "Disabled"
    end

    if mode ~= candidate.kind then
        return false, "TargetModeChanged"
    end

    if not isAliveAndPresent(candidate.model) then
        return false, "TargetUnavailable"
    end

    if candidate.kind == "Player" then
        if not candidate.player
            or not candidate.player:IsA("Player")
            or candidate.player.Parent ~= Players then
            return false, "PlayerUnavailable"
        end

        if candidate.player.Character ~= candidate.model then
            return false, "CharacterChanged"
        end

    elseif candidate.kind == "NPC" then
        if candidate.player ~= nil or not self:_isValidNPC(candidate.model) then
            return false, "NPCNoLongerEligible"
        end

    else
        return false, "InvalidCandidateKind"
    end

    local eligible = self.FactionValidator:IsEligible(
        self.LocalPlayer,
        candidate.player or candidate.model,
        candidate.kind
    )

    if not eligible then
        return false, "FactionNoLongerEligible"
    end

    return true, "OK"
end

return TargetDiscovery
