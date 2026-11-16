
-- Navigation Architecture v2.2
-- Foundation A: CharacterManager
-- Reconstructed implementation.
-- Compatible with the documented Foundation H interface.

local CharacterManager = {}
CharacterManager.__index = CharacterManager

function CharacterManager.new(localPlayer)
	assert(
		typeof(localPlayer) == "Instance"
			and localPlayer:IsA("Player"),
		"CharacterManager requires a valid Player"
	)

	local self = setmetatable({}, CharacterManager)

	self._player = localPlayer
	self._destroyed = false

	return self
end

function CharacterManager:GetCharacter()
	if self._destroyed or not self._player then
		return nil
	end

	local character = self._player.Character

	if character and character:IsA("Model") then
		return character
	end

	return nil
end

function CharacterManager:GetHumanoid(character)
	if self._destroyed then
		return nil
	end

	character = character or self:GetCharacter()

	if not character or not character:IsA("Model") then
		return nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")

	return humanoid
end

function CharacterManager:GetRoot(character)
	if self._destroyed then
		return nil
	end

	character = character or self:GetCharacter()

	if not character or not character:IsA("Model") then
		return nil
	end

	local humanoid = self:GetHumanoid(character)

	if humanoid then
		local humanoidRoot = humanoid.RootPart

		if humanoidRoot and humanoidRoot:IsA("BasePart") then
			return humanoidRoot
		end
	end

	local root = character:FindFirstChild("HumanoidRootPart")

	if root and root:IsA("BasePart") then
		return root
	end

	return nil
end

function CharacterManager:IsAlive(character)
	if self._destroyed then
		return false
	end

	character = character or self:GetCharacter()

	if not character then
		return false
	end

	local humanoid = self:GetHumanoid(character)

	if not humanoid then
		return false
	end

	return humanoid.Health > 0
end

function CharacterManager:IsAnchored(character)
	if self._destroyed then
		return false
	end

	local root = self:GetRoot(character)

	if not root then
		return false
	end

	return root.Anchored
end

function CharacterManager:Destroy()
	if self._destroyed then
		return
	end

	self._destroyed = true
	self._player = nil
end

return CharacterManager
