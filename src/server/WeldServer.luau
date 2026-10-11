local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local shared = ReplicatedStorage.Shared
local config = require(shared.WeldConfig)
local ObjectTargets = require(shared.ObjectTargets)
local WeldGeometry = require(shared.WeldGeometry)
local ConnectionGraph = require(shared.ConnectionGraph)
local ValidationRegistry = require(shared.ValidationRegistry)
local locks = require(script.Parent.InteractionLocks)

type Target = BasePart | Model
type WeldRecord = {
	a: Target, b: Target,
	folder: Folder, constraint: WeldConstraint, marker: BasePart,
	connections: {RBXScriptConnection},
}
type ObjectRig = {folder: Folder, count: number}
local WeldServer = {}
local graph = ConnectionGraph.new()
local validators = ValidationRegistry.new("WeldSystem", warn)
local unweldValidators = ValidationRegistry.new("UnweldSystem", warn)
local records: {[WeldRecord]: boolean} = {}
local markers: {[Instance]: WeldRecord} = {}
local rigs: {[Target]: ObjectRig} = {}
local weldFolder = Instance.new("Folder")
weldFolder.Name, weldFolder.Parent = "WeldConnections", workspace

local function retainRig(target: Target, root: BasePart)
	local existing = rigs[target]
	if existing then existing.count += 1; return end
	local folder = Instance.new("Folder")
	folder.Name, folder.Parent = "WeldObjectRig", target
	rigs[target] = {folder = folder, count = 1}
	for _, part in ObjectTargets.getParts({target}) do
		if part ~= root then
			local weld = Instance.new("WeldConstraint")
			weld.Part0, weld.Part1, weld.Parent = root, part, folder
		end
	end
end

local function releaseRig(target: Target)
	local rig = rigs[target]
	if not rig then return end
	rig.count -= 1
	if rig.count == 0 then rigs[target] = nil; rig.folder:Destroy() end
end

local function removeRecord(record: WeldRecord)
	if not records[record] then return end
	records[record] = nil
	markers[record.marker] = nil
	graph:RemoveEdge(record.a, record.b)
	for _, connection in record.connections do connection:Disconnect() end
	releaseRig(record.a)
	releaseRig(record.b)
	record.folder:Destroy()
end

local function isRecordValid(record: WeldRecord): boolean
	local weld = record.constraint
	return ObjectTargets.isSupported(record.a) and ObjectTargets.isSupported(record.b)
		and record.folder:IsDescendantOf(weldFolder) and weld:IsDescendantOf(record.folder)
		and record.marker:IsDescendantOf(record.folder)
		and weld.Enabled and weld.Part0 ~= nil and weld.Part1 ~= nil
		and (weld.Part0 == record.a or weld.Part0:IsDescendantOf(record.a))
		and (weld.Part1 == record.b or weld.Part1:IsDescendantOf(record.b))
end

local function prune()
	local stale = {}
	for record in records do
		if not isRecordValid(record) then table.insert(stale, record) end
	end
	for _, record in stale do removeRecord(record) end
end

function WeldServer.HasWeld(a: Target, b: Target): boolean
	prune()
	return graph:HasEdge(a, b)
end

function WeldServer.GetDirectConnections(target: Target): {Target}
	prune()
	return graph:GetDirect(target)
end

function WeldServer.GetIndirectConnections(target: Target): {Target}
	prune()
	return graph:GetIndirect(target)
end

function WeldServer.GetConnectedTargets(target: Target): {Target}
	prune()
	return graph:GetConnected(target)
end

function WeldServer.GetAssemblyTargets(target: Target): {Target}
	local targets = WeldServer.GetConnectedTargets(target)
	table.insert(targets, 1, target)
	return targets
end

function WeldServer.IsSameAssembly(target: Target, members: {Target}): boolean
	local current = WeldServer.GetAssemblyTargets(target)
	if #current ~= #members then return false end
	local expected = {}
	for _, member in members do expected[member] = true end
	for _, member in current do if not expected[member] then return false end end
	return true
end

function WeldServer.RemoveWeld(a: Target, b: Target): boolean
	for record in records do
		if (record.a == a and record.b == b) or (record.a == b and record.b == a) then
			removeRecord(record)
			return true
		end
	end
	return false
end

function WeldServer.RegisterWeldValidator(callback: (Target, Target, number?) -> boolean): () -> ()
	return validators:Register(callback)
end

function WeldServer.RegisterUnweldValidator(callback: (Target, Target, number?) -> boolean): () -> ()
	return unweldValidators:Register(callback)
end

local function findRecord(a: Target, b: Target): WeldRecord?
	prune()
	for record in records do
		if (record.a == a and record.b == b) or (record.a == b and record.b == a) then return record end
	end
	return nil
end

function WeldServer.GetWeldTargets(marker: any): (Target?, Target?)
	prune()
	local record = markers[marker]
	if record then return record.a, record.b end
	return nil, nil
end

local function reserveGroups(a: Target, b: Target): (() -> ())?
	local members = WeldServer.GetAssemblyTargets(a)
	for _, member in WeldServer.GetAssemblyTargets(b) do table.insert(members, member) end
	return locks:TryAcquire(ObjectTargets.getLockKeys(members, ObjectTargets.getParts(members)))
end

local function validPair(a: any, b: any): boolean
	return ObjectTargets.isSupported(a) and ObjectTargets.isSupported(b)
		and a ~= b and not a:IsDescendantOf(b) and not b:IsDescendantOf(a)
		and CollectionService:HasTag(a, config.TAG_NAME) and CollectionService:HasTag(b, config.TAG_NAME)
end

local function getContact(a: Target, b: Target): WeldGeometry.Contact?
	return WeldGeometry.closestContact(ObjectTargets.getParts({a}), ObjectTargets.getParts({b}))
end

local function inReach(player: Player, contact: WeldGeometry.Contact): boolean
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root ~= nil and root:IsA("BasePart")
		and (root.Position - contact.point0).Magnitude <= config.MAX_USE_DISTANCE
		and (root.Position - contact.point1).Magnitude <= config.MAX_USE_DISTANCE
end

local function populateRecord(a: Target, b: Target, contact: WeldGeometry.Contact, folder: Folder)
	for name, target in {Target0 = a, Target1 = b} do
		local value = Instance.new("ObjectValue")
		value.Name, value.Value, value.Parent = name, target, folder
	end
	local weld = Instance.new("WeldConstraint")
	weld.Name = "ObjectWeld"
	weld.Part0, weld.Part1, weld.Parent = contact.part0, contact.part1, folder
	local marker = Instance.new("Part")
	marker.Name, marker.Shape = "WeldPoint", Enum.PartType.Ball
	marker.Size, marker.Color = Vector3.one * config.MARKER_SIZE, config.MARKER_COLOR
	marker.Material = Enum.Material.Neon
	marker.CanCollide, marker.CanQuery, marker.CanTouch = false, true, false
	marker:SetAttribute(config.MARKER_ATTRIBUTE, true)
	marker.Massless, marker.CastShadow = true, false
	marker.CFrame = CFrame.new((contact.point0 + contact.point1) * 0.5)
	marker.Parent = folder
	local markerWeld = Instance.new("WeldConstraint")
	markerWeld.Name = "MarkerWeld"
	markerWeld.Part0, markerWeld.Part1, markerWeld.Parent = contact.part0, marker, folder
	local record: WeldRecord = {a = a, b = b, folder = folder, constraint = weld, marker = marker, connections = {}}
	records[record] = true
	markers[marker] = record
	graph:AddEdge(a, b)
	local function check()
		if not isRecordValid(record) then removeRecord(record) end
	end
	for _, instance in {a, b, contact.part0, contact.part1} do
		table.insert(record.connections, instance.AncestryChanged:Connect(check))
		table.insert(record.connections, instance.Destroying:Connect(function() removeRecord(record) end))
	end
	table.insert(record.connections, folder.Destroying:Connect(function() removeRecord(record) end))
	table.insert(record.connections, weld.Destroying:Connect(function() removeRecord(record) end))
	table.insert(record.connections, marker.Destroying:Connect(function() removeRecord(record) end))
	table.insert(record.connections, marker.AncestryChanged:Connect(check))
	for _, property in {"Enabled", "Part0", "Part1"} do
		table.insert(record.connections, weld:GetPropertyChangedSignal(property):Connect(check))
	end
end

local function createRecord(a: Target, b: Target, contact: WeldGeometry.Contact)
	local folder = Instance.new("Folder")
	folder.Name, folder.Parent = "Connection", weldFolder
	local retainedA, retainedB = false, false
	local ok, problem = pcall(function()
		retainedA = true
		retainRig(a, contact.part0)
		retainedB = true
		retainRig(b, contact.part1)
		populateRecord(a, b, contact, folder)
	end)
	if not ok then
		-- Roll back even if an engine/property error interrupted construction.
		local committed: WeldRecord? = nil
		for record in records do if record.folder == folder then committed = record; break end end
		if committed then removeRecord(committed) else
			if retainedA then releaseRig(a) end
			if retainedB then releaseRig(b) end
			folder:Destroy()
		end
		error(problem)
	end
end

-- Without an actor, server scripts skip player reach checks; object conditions still apply.
function WeldServer.Weld(a: Target, b: Target, playerUserId: number?, contextCheck: (() -> boolean)?): (boolean, string)
	prune()
	if not validPair(a, b) then return false, "InvalidTarget" end
	if graph:HasEdge(a, b) then return false, "AlreadyWelded" end
	local player = if playerUserId ~= nil then Players:GetPlayerByUserId(playerUserId) else nil
	if playerUserId ~= nil and not player then return false, "OutOfReach" end
	local release = reserveGroups(a, b)
	if not release then return false, "Busy" end
	local succeeded, allowed, reason = pcall(function(): (boolean, string)
		local contact = getContact(a, b)
		if not contact or contact.distance > config.MAX_WELD_DISTANCE then return false, "TooFar" end
		if player and not inReach(player, contact) then return false, "OutOfReach" end
		if not validators:Check(a, b, playerUserId) then return false, "Denied" end
		-- Validators may yield, so recheck before changing the scene.
		if not validPair(a, b) or graph:HasEdge(a, b) or (player and player.Parent ~= Players) then
			return false, "InvalidTarget"
		end
		if contextCheck and not contextCheck() then return false, "EquipTool" end
		contact = getContact(a, b)
		if not contact or contact.distance > config.MAX_WELD_DISTANCE then return false, "TooFar" end
		if player and not inReach(player, contact) then return false, "OutOfReach" end
		createRecord(a, b, contact)
		return true, "Welded"
	end)
	release()
	if not succeeded then warn("WeldSystem: weld creation failed:", allowed); return false, "Failed" end
	return allowed, reason
end

function WeldServer.TryWeld(a: Target, b: Target, playerUserId: number): (boolean, string)
	return WeldServer.Weld(a, b, playerUserId)
end

function WeldServer.Unweld(a: Target, b: Target, playerUserId: number?, contextCheck: (() -> boolean)?): (boolean, string)
	local record = findRecord(a, b)
	if not record then return false, "NotWelded" end
	local player = if playerUserId ~= nil then Players:GetPlayerByUserId(playerUserId) else nil
	if playerUserId ~= nil and not player then return false, "OutOfReach" end
	local release = reserveGroups(a, b)
	if not release then return false, "Busy" end
	local function canReach(): boolean
		if not player then return true end
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		return player.Parent == Players and root ~= nil and root:IsA("BasePart")
			and (root.Position - record.marker.Position).Magnitude <= config.MAX_USE_DISTANCE
	end
	local succeeded, allowed, reason = pcall(function(): (boolean, string)
		if not canReach() then return false, "OutOfReach" end
		if not unweldValidators:Check(a, b, playerUserId) then return false, "Denied" end
		-- The exact record must survive a yielding condition; never remove a replacement weld.
		if not records[record] or not isRecordValid(record) then return false, "NotWelded" end
		if contextCheck and not contextCheck() then return false, "EquipTool" end
		if not canReach() then return false, "OutOfReach" end
		removeRecord(record)
		return true, "Unwelded"
	end)
	release()
	if not succeeded then warn("UnweldSystem: removal failed:", allowed); return false, "Failed" end
	return allowed, reason
end

function WeldServer.UnweldMarker(marker: any, playerUserId: number, contextCheck: (() -> boolean)?): (boolean, string)
	local a, b = WeldServer.GetWeldTargets(marker)
	if not a or not b then return false, "InvalidMarker" end
	return WeldServer.Unweld(a, b, playerUserId, contextCheck)
end

function WeldServer.WeldNearest(target: Target, playerUserId: number, contextCheck: (() -> boolean)?): (boolean, string, Target?)
	if not ObjectTargets.isSupported(target) or not CollectionService:HasTag(target, config.TAG_NAME) then
		return false, "InvalidTarget"
	end
	local nearest: Target? = nil
	local nearestDistance = math.huge
	local seen = {}
	for _, tagged in CollectionService:GetTagged(config.TAG_NAME) do
		local candidate = ObjectTargets.findTagged(tagged, config.TAG_NAME)
		if candidate and not seen[candidate] then
			seen[candidate] = true
			if validPair(target, candidate) and not WeldServer.HasWeld(target, candidate) then
				local contact = getContact(target, candidate)
				if contact and contact.distance < nearestDistance then
					nearest, nearestDistance = candidate, contact.distance
				end
			end
		end
	end
	if not nearest or nearestDistance > config.MAX_WELD_DISTANCE then return false, "NoNearbyTarget" end
	local allowed, reason = WeldServer.Weld(target, nearest, playerUserId, contextCheck)
	return allowed, reason, nearest
end

return table.freeze(WeldServer)
