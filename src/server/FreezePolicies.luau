-- Optional gameplay rules use FreezeServer's API rather than owning freeze state.
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local shared = ReplicatedStorage.Shared
local config = require(shared.FreezeConfig)
local ObjectTargets = require(shared.ObjectTargets)
local InteractionCharacter = require(shared.InteractionCharacter)
local FreezeServer = require(script.Parent.FreezeServer)
local DragServer = require(script.Parent.DragServer)
local WeldServer = require(script.Parent.WeldServer)
local FreezePolicies = {}
local started = false
type ContactState = {id: number, time: number, previous: {[BasePart]: boolean}}
local contactsByTarget: {[Instance]: ContactState} = {}

local function inRange(parts: {BasePart}, position: Vector3): boolean
	if config.UNFREEZE_DISTANCE <= 0 then return true end
	for _, part in parts do
		local localPoint = part.CFrame:PointToObjectSpace(position)
		local half = part.Size * 0.5
		local closest = Vector3.new(math.clamp(localPoint.X, -half.X, half.X),
			math.clamp(localPoint.Y, -half.Y, half.Y), math.clamp(localPoint.Z, -half.Z, half.Z))
		if (localPoint - closest).Magnitude <= config.UNFREEZE_DISTANCE then return true end
	end
	return false
end

local function enforceLimit(userId: number, reserveNew: boolean)
	local allowed = math.max(math.floor(config.MAX_FROZEN_MODELS) - (if reserveNew then 1 else 0), 0)
	local models = FreezeServer.GetFrozenModels(userId)
	for index = 1, math.max(#models - allowed, 0) do FreezeServer.Unfreeze(models[index], "Limit") end
end

local function ignoredCollision(part: BasePart): boolean
	local ancestor: Instance? = part
	while ancestor and ancestor ~= workspace do
		if CollectionService:HasTag(ancestor, config.IGNORE_COLLISION_TAG) then return true end
		ancestor = ancestor.Parent
	end
	return false
end

local function getContacts(info: FreezeServer.Info): {[BasePart]: boolean}
	local result, ownParts = {}, {}
	for _, part in info.parts do ownParts[part] = true end
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = info.parts
	params.RespectCanCollide = true
	params.Tolerance = config.COLLISION_TOLERANCE
	for _, part in info.parts do
		if part:IsDescendantOf(workspace) and part.CanCollide then
			params.CollisionGroup = part.CollisionGroup
			for _, other in workspace:GetPartsInPart(part, params) do
				if not ownParts[other] and other:IsDescendantOf(workspace) and other.CanCollide
					and ObjectTargets.isFiniteCFrame(other.CFrame) then result[other] = true end
			end
		end
	end
	return result
end

local function track(target: Instance, _userId: number, info: FreezeServer.Info)
	if config.UNFREEZE_ON_COLLISION then
		contactsByTarget[target] = {id = info.id, time = os.clock(), previous = getContacts(info)}
	end
end

function FreezePolicies.Step()
	FreezeServer.Prune()
	for _, target in FreezeServer.GetFrozenModels() do
		local info = FreezeServer.GetFrozenInfo(target)
		if not info then continue end
		local player = Players:GetPlayerByUserId(info.playerUserId)
		local root = if player and player.Parent == Players then InteractionCharacter.getRoot(player) else nil
		if not root then FreezeServer.Unfreeze(target, "OwnerUnavailable"); continue end
		if not inRange(info.parts, root.Position) then FreezeServer.Unfreeze(target, "Distance"); continue end
		if not config.UNFREEZE_ON_COLLISION then contactsByTarget[target] = nil; continue end
		local state = contactsByTarget[target]
		if not state or state.id ~= info.id then track(target, info.playerUserId, info); continue end
		if os.clock() - state.time < config.COLLISION_GRACE_TIME then continue end
		local current = getContacts(info)
		for other in current do
			if not state.previous[other] and not ignoredCollision(other) then
				FreezeServer.Unfreeze(target, "Collision")
				break
			end
		end
		state.previous = current
	end
end

function FreezePolicies.Start()
	if started then return end
	started = true
	FreezeServer.RegisterFreezeValidator(function(target, userId)
		local player = Players:GetPlayerByUserId(userId)
		local root = if player then InteractionCharacter.getRoot(player) else nil
		return config.MAX_FROZEN_MODELS > 0 and root ~= nil
			and inRange(ObjectTargets.getParts(WeldServer.GetAssemblyTargets(target)), root.Position)
	end)
	DragServer.Grabbed:Connect(function(_target, userId) enforceLimit(userId, true) end)
	FreezeServer.Frozen:Connect(function(target, userId, info)
		local current = FreezeServer.GetFrozenInfo(target)
		if not current or current.id ~= info.id then return end
		local player = Players:GetPlayerByUserId(userId)
		local root = if player then InteractionCharacter.getRoot(player) else nil
		if not root or not inRange(info.parts, root.Position) then FreezeServer.Unfreeze(target, "Distance"); return end
		track(target, userId, info)
		enforceLimit(userId, false)
	end)
	FreezeServer.Unfrozen:Connect(function(target, _userId, _reason, info)
		local state = contactsByTarget[target]
		if state and state.id == info.id then contactsByTarget[target] = nil end
	end)
	Players.PlayerRemoving:Connect(function(player) FreezeServer.UnfreezeAll(player.UserId, "PlayerLeft") end)
	local elapsed = 0
	RunService.Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed < config.CHECK_INTERVAL then return end
		elapsed = 0
		FreezePolicies.Step()
	end)
	local owners = {}
	for _, target in FreezeServer.GetFrozenModels() do
		local info = FreezeServer.GetFrozenInfo(target)
		if info then track(target, info.playerUserId, info); owners[info.playerUserId] = true end
	end
	for userId in owners do enforceLimit(userId, false) end
end

return table.freeze(FreezePolicies)
