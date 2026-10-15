-- Freeze records and conditions only; gameplay policies subscribe through the public API.
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local shared = ReplicatedStorage.Shared
local config = require(shared.FreezeConfig)
local ObjectTargets = require(shared.ObjectTargets)
local ObjectMechanisms = require(shared.ObjectMechanisms)
local InteractionCharacter = require(shared.InteractionCharacter)
local ValidationRegistry = require(shared.ValidationRegistry)
local WeldServer = require(script.Parent.WeldServer)
local ServerOwnership = require(script.Parent.ServerOwnership)
local locks = require(script.Parent.InteractionLocks)
type Target = ObjectTargets.Target
export type Info = {target: Target, playerUserId: number, id: number, members: {Target}, parts: {BasePart}}
type Record = {target: Target, playerUserId: number, id: number, members: {Target}, parts: {BasePart}}
type Pending = {playerUserId: number, character: Model, cancelled: boolean, release: () -> ()}
local records: {[Record]: boolean} = {}
local byMember: {[Instance]: Record} = {}
local byPart: {[BasePart]: Record} = {}
local pending: {[Pending]: boolean} = {}
local nextId = 0
local validators = ValidationRegistry.new("FreezeSystem", warn)
local frozenEvent, unfrozenEvent = Instance.new("BindableEvent"), Instance.new("BindableEvent")
local FreezeServer = {Frozen = frozenEvent.Event, Unfrozen = unfrozenEvent.Event}

local function info(record: Record): Info
	return {target = record.target, playerUserId = record.playerUserId, id = record.id,
		members = table.clone(record.members), parts = table.clone(record.parts)}
end

local function findRecord(target: Instance): Record?
	return byMember[target] or byPart[target :: BasePart]
end

function FreezeServer.IsFrozen(target: Instance): boolean
	return findRecord(target) ~= nil
end

function FreezeServer.GetFrozenInfo(target: Instance): Info?
	local record = findRecord(target)
	return if record then info(record) else nil
end

-- Oldest first; return representatives, not duplicate entries for every welded member.
function FreezeServer.GetFrozenModels(playerUserId: number?): {Target}
	local ordered = {}
	for record in records do
		if playerUserId == nil or record.playerUserId == playerUserId then table.insert(ordered, record) end
	end
	table.sort(ordered, function(a, b) return a.id < b.id end)
	local result = {}
	for _, record in ordered do table.insert(result, record.target) end
	return result
end

function FreezeServer.Unfreeze(target: Instance, reason: string?): boolean
	local record = findRecord(target)
	if not record then return false end
	records[record] = nil
	for _, member in record.members do if byMember[member] == record then byMember[member] = nil end end
	for _, part in record.parts do
		if byPart[part] == record then byPart[part] = nil end
		if part.Parent then
			part.AssemblyLinearVelocity, part.AssemblyAngularVelocity = Vector3.zero, Vector3.zero
			part.Anchored = false
		end
	end
	ServerOwnership.Claim(record.parts)
	unfrozenEvent:Fire(record.target, record.playerUserId, reason or "API", info(record))
	return true
end

local function cancel(request: Pending)
	request.cancelled = true
	pending[request] = nil
	request.release()
end

function FreezeServer.UnfreezeAll(playerUserId: number, reason: string?): number
	for request in table.clone(pending) do
		if request.playerUserId == playerUserId then cancel(request) end
	end
	local count = 0
	for _, target in FreezeServer.GetFrozenModels(playerUserId) do
		if FreezeServer.Unfreeze(target, reason) then count += 1 end
	end
	return count
end

-- Called after grab validation, before creating its temporary rig, while drag locks are held.
function FreezeServer.UnfreezeMembers(members: {Target}, reason: string?)
	local affected = {}
	for _, member in members do
		local record = findRecord(member)
		if record then affected[record] = true end
	end
	for _, part in ObjectTargets.getParts(members) do
		local record = byPart[part]
		if record then affected[record] = true end
	end
	for record in affected do FreezeServer.Unfreeze(record.target, reason or "Grabbed") end
end

function FreezeServer.RegisterFreezeValidator(callback: (Target, number) -> boolean): () -> ()
	return validators:Register(callback)
end

local function validGroup(target: Target, members: {Target}, parts: {BasePart}): boolean
	if not ObjectTargets.isSupported(target) or not CollectionService:HasTag(target, config.TAG_NAME)
		or not WeldServer.IsSameAssembly(target, members) then return false end
	for _, member in members do
		if not ObjectTargets.isSupported(member) or ObjectMechanisms.hasOccupant(member)
			or (config.REQUIRE_ALL_MEMBERS_FREEZABLE and not CollectionService:HasTag(member, config.TAG_NAME)) then return false end
	end
	local current = ObjectTargets.getParts(members)
	if #current ~= #parts or #parts == 0 then return false end
	local expected = {}
	for _, part in parts do
		if not part:IsDescendantOf(workspace) or not ObjectTargets.isFiniteCFrame(part.CFrame) then return false end
		expected[part] = true
	end
	for _, part in current do if not expected[part] then return false end end
	return true
end

function FreezeServer.Freeze(target: Target, playerUserId: number, contextCheck: (() -> boolean)?): (boolean, string)
	if typeof(playerUserId) ~= "number" or not (playerUserId > 0 and playerUserId < math.huge)
		or playerUserId ~= math.floor(playerUserId) then return false, "InvalidPlayer" end
	local player = Players:GetPlayerByUserId(playerUserId)
	if not player or player.Parent ~= Players or not InteractionCharacter.getRoot(player)
		or not ObjectTargets.isSupported(target) then return false, "InvalidTarget" end
	local members = WeldServer.GetAssemblyTargets(target)
	local parts = ObjectTargets.getParts(members)
	if not validGroup(target, members, parts) then return false, "Denied" end
	for _, part in parts do if byPart[part] then return false, "AlreadyFrozen" end end
	local release = locks:TryAcquire(ObjectTargets.getLockKeys(members, parts))
	if not release then return false, "Busy" end
	local request: Pending = {playerUserId = playerUserId, character = player.Character, cancelled = false, release = release}
	pending[request] = true
	local ok, allowed, reason = pcall(function(): (boolean, string)
		for _, member in members do
			if request.cancelled or not validators:Check(member, playerUserId) then return false, "Denied" end
		end
		if request.cancelled or player.Parent ~= Players or player.Character ~= request.character
			or not InteractionCharacter.getRoot(player) or not validGroup(target, members, parts)
			or (contextCheck and not contextCheck()) then return false, "Cancelled" end
		nextId += 1
		local record: Record = {target = target, playerUserId = playerUserId, id = nextId, members = members, parts = parts}
		local anchored = {}
		local anchoredOK, problem = pcall(function()
			for _, part in parts do
				anchored[part] = part.Anchored
				part.AssemblyLinearVelocity, part.AssemblyAngularVelocity = Vector3.zero, Vector3.zero
				part.Anchored = true
			end
		end)
		if not anchoredOK then
			for part, wasAnchored in anchored do if part.Parent then part.Anchored = wasAnchored end end
			error(problem)
		end
		records[record] = true
		for _, member in members do byMember[member] = record end
		for _, part in parts do byPart[part] = record end
		pending[request] = nil
		release()
		frozenEvent:Fire(target, playerUserId, info(record))
		return true, "Frozen"
	end)
	pending[request] = nil
	release()
	if not ok then warn("FreezeSystem: freeze failed:", allowed); return false, "Failed" end
	return allowed, reason
end

function FreezeServer.Prune()
	for request in table.clone(pending) do
		local player = Players:GetPlayerByUserId(request.playerUserId)
		if not player or player.Parent ~= Players or player.Character ~= request.character
			or not InteractionCharacter.getRoot(player) then cancel(request) end
	end
	for record in table.clone(records) do
		local valid = validGroup(record.target, record.members, record.parts)
		for _, part in record.parts do if not part.Anchored then valid = false; break end end
		if not valid then FreezeServer.Unfreeze(record.target, "Invalidated") end
	end
end

return table.freeze(FreezeServer)
