
-- Navigation Architecture v2.2
-- Foundation B: FactionValidator
-- Reconstructed implementation based on v2.1 faction rules
-- and the documented v2.2 public interface.

local FactionValidator = {}
FactionValidator.__index = FactionValidator

local function isInstanceOf(value, className)
	return typeof(value) == "Instance" and value:IsA(className)
end

local function readAttribute(instance, attributeName)
	if not instance or type(attributeName) ~= "string" then
		return nil
	end

	local success, value = pcall(function()
		return instance:GetAttribute(attributeName)
	end)

	if success then
		return value
	end

	return nil
end

function FactionValidator.new(config)
	assert(type(config) == "table", "FactionValidator requires a config table")
	assert(
		type(config.factionAttribute) == "string"
			and config.factionAttribute ~= "",
		"FactionValidator requires a valid factionAttribute"
	)

	return setmetatable({
		Config = config,
	}, FactionValidator)
end

function FactionValidator:GetPlayerFaction(player)
	if not isInstanceOf(player, "Player") then
		return nil, "InvalidPlayer"
	end

	local faction = readAttribute(player, self.Config.factionAttribute)

	if faction ~= nil then
		return faction, "PlayerAttribute"
	end

	local characterFaction = readAttribute(
		player.Character,
		self.Config.factionAttribute
	)

	if characterFaction ~= nil then
		return characterFaction, "CharacterAttribute"
	end

	return nil, "Unclassified"
end

function FactionValidator:GetModelFaction(model)
	if not isInstanceOf(model, "Model") then
		return nil, "InvalidModel"
	end

	local faction = readAttribute(model, self.Config.factionAttribute)

	if faction ~= nil then
		return faction, "ModelAttribute"
	end

	return nil, "Unclassified"
end

function FactionValidator:Classify(localPlayer, candidate)
	if not isInstanceOf(localPlayer, "Player") then
		return "InvalidLocalPlayer", "InvalidLocalPlayer", "InvalidCandidate"
	end

	if isInstanceOf(candidate, "Player") then
		if candidate == localPlayer then
			return "Self", "Self", "Self"
		end

		if localPlayer.Neutral or candidate.Neutral then
			return "Neutral", "Neutral", "Neutral"
		end

		local localFaction, localSource =
			self:GetPlayerFaction(localPlayer)

		local candidateFaction, candidateSource =
			self:GetPlayerFaction(candidate)

		if localFaction ~= nil and candidateFaction ~= nil then
			if localFaction == candidateFaction then
				return "SameFaction", localSource, candidateSource
			end

			return "OpposingFaction", localSource, candidateSource
		end

		if localPlayer.TeamColor ~= nil
			and candidate.TeamColor ~= nil then

			if localPlayer.TeamColor == candidate.TeamColor then
				return "SameFaction", "TeamColor", "TeamColor"
			end

			return "OpposingFaction", "TeamColor", "TeamColor"
		end

		return "Unclassified", localSource, candidateSource
	end

	if isInstanceOf(candidate, "Model") then
		local localFaction, localSource =
			self:GetPlayerFaction(localPlayer)

		local candidateFaction, candidateSource =
			self:GetModelFaction(candidate)

		if localFaction ~= nil and candidateFaction ~= nil then
			if localFaction == candidateFaction then
				return "SameFaction", localSource, candidateSource
			end

			return "OpposingFaction", localSource, candidateSource
		end

		return "Unclassified", localSource, candidateSource
	end

	return "InvalidCandidate", "Unknown", "Unknown"
end

function FactionValidator:IsEligible(localPlayer, candidate, targetKind)
	if not isInstanceOf(localPlayer, "Player") then
		return false, "InvalidLocalPlayer", "Unknown", "Unknown"
	end

	if targetKind ~= "Player" and targetKind ~= "NPC" then
		return false, "InvalidTargetKind", "Unknown", "Unknown"
	end

	if targetKind == "Player" then
		if not isInstanceOf(candidate, "Player") then
			return false, "InvalidPlayerCandidate", "Unknown", "Unknown"
		end

		if candidate == localPlayer then
			return false, "Self", "Self", "Self"
		end

		if localPlayer.Neutral or candidate.Neutral then
			return false, "Neutral", "Neutral", "Neutral"
		end
	elseif not isInstanceOf(candidate, "Model") then
		return false, "InvalidNPCCandidate", "Unknown", "Unknown"
	end

	local classification, localSource, candidateSource =
		self:Classify(localPlayer, candidate)

	if classification == "OpposingFaction" then
		return true, classification, localSource, candidateSource
	end

	if targetKind == "NPC"
		and classification == "Unclassified"
		and self.Config.allowUnclassifiedNPCs == true then
		return true, "UnclassifiedNPCAllowed", localSource, candidateSource
	end

	return false, classification, localSource, candidateSource
end

return FactionValidator
