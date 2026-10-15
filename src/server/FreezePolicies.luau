-- Optional gameplay rules use FreezeServer's API rather than owning freeze state.
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local PhysicsService = game:GetService("PhysicsService")
local shared = ReplicatedStorage.Shared
local config = require(shared.FreezeConfig)
local ObjectTargets = require(shared.ObjectTargets)
local InteractionCharacter = require(shared.InteractionCharacter)
local FreezeServer = require(script.Parent.FreezeServer)
local WeldServer = require(script.Parent.WeldServer)
local WeldGeometry = require(shared.WeldGeometry)
local FreezePolicies = {}
local started = false
type ContactState = {
	id: number, time: number, previous: {[BasePart]: boolean},
	queued: {[BasePart]: boolean}, connections: {RBXScriptConnection},
}
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

local function enforceLimit(userId: number)
	local allowed = math.max(math.floor(config.MAX_FROZEN_MODELS), 0)
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

local function isCharacterBody(part: BasePart): boolean
	local character = part.Parent
	if not character or not character:IsA("Model") then return false end
	local humanoid = character:FindFirstChildWhichIsA("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

local function eligibleContact(part: BasePart, other: any, ownParts: {[BasePart]: boolean}): boolean
	return typeof(other) == "Instance" and other:IsA("BasePart") and not ownParts[other]
		and part.CanCollide and other:IsDescendantOf(workspace)
		and (other.CanCollide or isCharacterBody(other))
		and ObjectTargets.isFiniteCFrame(other.CFrame)
		and PhysicsService:CollisionGroupsAreCollidable(part.CollisionGroup, other.CollisionGroup)
end

local function nearSurface(part: BasePart, other: BasePart): boolean
	local distance = math.max(config.COLLISION_CONTACT_DISTANCE, 0)
	-- Reject distant/spoofed touch reports before the more expensive surface query.
	local center = part.CFrame:PointToObjectSpace(other.Position)
	local half = part.Size * 0.5
	local radius = other.Size.Magnitude * 0.5 + distance
	if math.abs(center.X) > half.X + radius or math.abs(center.Y) > half.Y + radius
		or math.abs(center.Z) > half.Z + radius then return false end
	local contact = WeldGeometry.closestContact({part}, {other})
	return contact ~= nil and contact.distance <= distance + 1e-4
end

local function getContacts(info: FreezeServer.Info): {[BasePart]: boolean}
	local result, ownParts = {}, {}
	for _, part in info.parts do ownParts[part] = true end
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = info.parts
	params.RespectCanCollide = true
	params.Tolerance = config.COLLISION_TOLERANCE
	local nearbyParams = OverlapParams.new()
	nearbyParams.FilterType = Enum.RaycastFilterType.Exclude
	nearbyParams.FilterDescendantsInstances = info.parts
	nearbyParams.RespectCanCollide = false -- Avatar limbs may be noncollidable but still touch the model.
	local skin = Vector3.one * (math.max(config.COLLISION_CONTACT_DISTANCE, 0) * 2)
	for _, part in info.parts do
		if part:IsDescendantOf(workspace) and part.CanCollide then
			params.CollisionGroup = part.CollisionGroup
			nearbyParams.CollisionGroup = part.CollisionGroup
			for _, other in workspace:GetPartsInPart(part, params) do
				if eligibleContact(part, other, ownParts) then result[other] = true end
			end
			for _, other in part:GetTouchingParts() do
				if not result[other] and eligibleContact(part, other, ownParts)
					and nearSurface(part, other) then result[other] = true end
			end
			for _, other in workspace:GetPartBoundsInBox(part.CFrame, part.Size + skin, nearbyParams) do
				if not result[other] and eligibleContact(part, other, ownParts)
					and nearSurface(part, other) then result[other] = true end
			end
		end
	end
	return result
end

local function clearContacts(target: Instance)
	local state = contactsByTarget[target]
	if not state then return end
	contactsByTarget[target] = nil
	for _, connection in state.connections do connection:Disconnect() end
end

local function track(target: Instance, _userId: number, info: FreezeServer.Info)
	clearContacts(target)
	if config.UNFREEZE_ON_COLLISION then
		local state: ContactState = {id = info.id, time = os.clock(), previous = {}, queued = {}, connections = {}}
		contactsByTarget[target] = state
		local ownParts = {}
		for _, part in info.parts do ownParts[part] = true end
		for _, part in info.parts do
			if not part.CanTouch then continue end
			table.insert(state.connections, part.Touched:Connect(function(other)
				if contactsByTarget[target] ~= state or state.previous[other] or state.queued[other]
					or not config.UNFREEZE_ON_COLLISION or not part:IsDescendantOf(workspace)
					or not part.CanTouch or not eligibleContact(part, other, ownParts)
					or not other.CanTouch or ignoredCollision(other) then return end
				local current = FreezeServer.GetFrozenInfo(target)
				if current and current.id == state.id and nearSurface(part, other) then
					-- Keep verified brief impacts even if they end before the next policy tick.
					state.queued[other] = true
				end
			end))
		end
		state.previous = getContacts(info)
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
		if not config.UNFREEZE_ON_COLLISION then clearContacts(target); continue end
		local state = contactsByTarget[target]
		if not state or state.id ~= info.id then track(target, info.playerUserId, info); continue end
		if os.clock() - state.time < config.COLLISION_GRACE_TIME then continue end
		local current = getContacts(info)
		for other in state.queued do
			if not ignoredCollision(other) then current[other] = true end
		end
		table.clear(state.queued)
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
	FreezeServer.Frozen:Connect(function(target, userId, info)
		local current = FreezeServer.GetFrozenInfo(target)
		if not current or current.id ~= info.id then return end
		local player = Players:GetPlayerByUserId(userId)
		local root = if player then InteractionCharacter.getRoot(player) else nil
		if not root or not inRange(info.parts, root.Position) then FreezeServer.Unfreeze(target, "Distance"); return end
		track(target, userId, info)
		enforceLimit(userId)
	end)
	FreezeServer.Unfrozen:Connect(function(target, _userId, _reason, info)
		local state = contactsByTarget[target]
		if state and state.id == info.id then clearContacts(target) end
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
	for userId in owners do enforceLimit(userId) end
end

return table.freeze(FreezePolicies)
