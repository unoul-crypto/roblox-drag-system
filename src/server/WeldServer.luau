local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local shared = ReplicatedStorage.Shared
local config = require(shared.WeldConfig)
local ObjectTargets = require(shared.ObjectTargets)
local ObjectMechanisms = require(shared.ObjectMechanisms)
local InteractionCharacter = require(shared.InteractionCharacter)
local InteractionVisibility = require(shared.InteractionVisibility)
local WeldGeometry = require(shared.WeldGeometry)
local HingeGeometry = require(shared.HingeGeometry)
local hingeConfig = require(shared.HingeConfig)
local ConnectionGraph = require(shared.ConnectionGraph)
local ValidationRegistry = require(shared.ValidationRegistry)
local locks = require(script.Parent.InteractionLocks)

type Target = BasePart | Model
type MarkerPoint = {part: BasePart, point: Vector3}
type MarkerAppearance = {MARKER_SIZE: number, MARKER_COLOR: Color3}
type WeldRecord = {
	a: Target, b: Target,
	folder: Folder, constraint: WeldConstraint | HingeConstraint, marker: BasePart,
	kind: string, attachments: {Attachment},
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
	if ObjectMechanisms.isPreserved(target) then return end
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
	for _, attachment in record.attachments do attachment:Destroy() end
	releaseRig(record.a)
	releaseRig(record.b)
	record.folder:Destroy()
end

local function isRecordValid(record: WeldRecord): boolean
	local weld = record.constraint
	local part0, part1
	if record.kind == "Hinge" then
		local a, b = weld.Attachment0, weld.Attachment1
		if not a or not b or not a:IsA("Attachment") or not b:IsA("Attachment") then return false end
		part0, part1 = a.Parent, b.Parent
	else part0, part1 = weld.Part0, weld.Part1 end
	return ObjectTargets.isSupported(record.a) and ObjectTargets.isSupported(record.b)
		and record.folder:IsDescendantOf(weldFolder) and weld:IsDescendantOf(record.folder)
		and record.marker:IsDescendantOf(record.folder)
		and weld.Enabled and part0 ~= nil and part1 ~= nil and part0:IsA("BasePart") and part1:IsA("BasePart")
		and (part0 == record.a or part0:IsDescendantOf(record.a))
		and (part1 == record.b or part1:IsDescendantOf(record.b))
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

function WeldServer.CheckConnectionConditions(a: Target, b: Target, playerUserId: number): boolean
	return validators:Check(a,b,playerUserId)
end

local function findRecord(a: Target, b: Target): WeldRecord?
	prune()
	for record in records do
		if (record.a == a and record.b == b) or (record.a == b and record.b == a) then return record end
	end
	return nil
end

function WeldServer.GetConnectionType(a: Target, b: Target): string?
	local record = findRecord(a, b)
	return if record then record.kind else nil
end

function WeldServer.HasHinge(a: Target, b: Target): boolean
	return WeldServer.GetConnectionType(a, b) == "Hinge"
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
	return WeldGeometry.closestContact(ObjectMechanisms.getWeldParts(a), ObjectMechanisms.getWeldParts(b))
end

local function inReach(player: Player, contact: WeldGeometry.Contact): boolean
	local root = InteractionCharacter.getRoot(player)
	return root ~= nil
		and (root.Position - contact.point0).Magnitude <= config.MAX_USE_DISTANCE
		and (root.Position - contact.point1).Magnitude <= config.MAX_USE_DISTANCE
end

local function markerPosition(target: Target, selection: MarkerPoint): Vector3?
	if type(selection) ~= "table" or not ObjectTargets.isSupported(selection.part) or not selection.part:IsA("BasePart")
		or (selection.part ~= target and not selection.part:IsDescendantOf(target))
		or typeof(selection.point) ~= "Vector3" or not ObjectTargets.isFiniteVector(selection.point)
		or not ObjectTargets.isFiniteCFrame(selection.part.CFrame) then return nil end
	local point = selection.part.CFrame:PointToWorldSpace(selection.point)
	return if ObjectTargets.containsPoint(selection.part, point) then point else nil
end

local function populateRecord(a: Target, b: Target, contact: WeldGeometry.Contact, folder: Folder,
	endpoints: {HingeGeometry.Endpoint}?, attachments: {Attachment}, selection: MarkerPoint?, markerConfig: MarkerAppearance?)
	for name, target in {Target0 = a, Target1 = b} do
		local value = Instance.new("ObjectValue")
		value.Name, value.Value, value.Parent = name, target, folder
	end
	local kind = if endpoints then "Hinge" else "Weld"
	local weld
	if endpoints then
		for index, endpoint in endpoints do
			local attachment = Instance.new("Attachment")
			table.insert(attachments, attachment)
			attachment.Name = "ObjectHingeAttachment" .. index
			attachment.Position, attachment.Axis = endpoint.point, endpoint.axis
			attachment.SecondaryAxis = HingeGeometry.secondary(endpoint.axis)
			attachment.Parent = endpoint.part
		end
		weld = Instance.new("HingeConstraint")
		weld.Name, weld.Attachment0, weld.Attachment1 = "ObjectHinge", attachments[1], attachments[2]
		weld.ActuatorType, weld.LimitsEnabled = Enum.ActuatorType.None, false
	else
		weld = Instance.new("WeldConstraint")
		weld.Name, weld.Part0, weld.Part1 = "ObjectWeld", contact.part0, contact.part1
	end
	weld.Parent = folder
	folder:SetAttribute("ConnectionType", kind)
	local marker = Instance.new("Part")
	marker.Name, marker.Shape = "WeldPoint", Enum.PartType.Ball
	local appearance = markerConfig or (if endpoints then hingeConfig else config)
	marker.Size, marker.Color = Vector3.one * appearance.MARKER_SIZE, appearance.MARKER_COLOR
	marker.Material = Enum.Material.Neon
	marker.CanCollide, marker.CanQuery, marker.CanTouch = false, true, false
	marker:SetAttribute(config.MARKER_ATTRIBUTE, true)
	marker.Massless, marker.CastShadow = true, false
	marker.CFrame = CFrame.new(if selection then markerPosition(a, selection) :: Vector3 else (contact.point0 + contact.point1) * 0.5)
	marker.Parent = folder
	local markerWeld = Instance.new("WeldConstraint")
	markerWeld.Name = "MarkerWeld"
	markerWeld.Part0, markerWeld.Part1, markerWeld.Parent = if selection then selection.part else contact.part0, marker, folder
	local record: WeldRecord = {a = a, b = b, folder = folder, constraint = weld, marker = marker,
		kind = kind, attachments = attachments, connections = {}}
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
	for _, attachment in attachments do
		table.insert(record.connections, attachment.Destroying:Connect(function() removeRecord(record) end))
		table.insert(record.connections, attachment.AncestryChanged:Connect(check))
	end
	for _, property in if endpoints then {"Enabled", "Attachment0", "Attachment1"} else {"Enabled", "Part0", "Part1"} do
		table.insert(record.connections, weld:GetPropertyChangedSignal(property):Connect(check))
	end
end

local function createRecord(a: Target, b: Target, contact: WeldGeometry.Contact, endpoints: {HingeGeometry.Endpoint}?, selection: MarkerPoint?, markerConfig: MarkerAppearance?)
	local folder = Instance.new("Folder")
	folder.Name, folder.Parent = "Connection", weldFolder
	local retainedA, retainedB = false, false
	local attachments = {}
	local ok, problem = pcall(function()
		retainedA = true
		retainRig(a, contact.part0)
		retainedB = true
		retainRig(b, contact.part1)
		populateRecord(a, b, contact, folder, endpoints, attachments, selection, markerConfig)
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
		for _, attachment in attachments do attachment:Destroy() end
		error(problem)
	end
end

-- Finalize a physical point pull only after both points and axes have settled.
-- The public entry point owns its reservation and rechecks after yielding validators.
function WeldServer.ConnectPoints(endpoint0: HingeGeometry.Endpoint, endpoint1: HingeGeometry.Endpoint,
	kind: string, playerUserId: number, contextCheck: (() -> boolean)?): (boolean, string)
	if kind ~= "Weld" and kind ~= "Hinge" then return false, "InvalidTarget" end
	if not HingeGeometry.valid(endpoint0) or not HingeGeometry.valid(endpoint1) then return false, "InvalidTarget" end
	local a, b = endpoint0.target, endpoint1.target
	if not validPair(a, b) or graph:HasEdge(a, b) then return false, "InvalidTarget" end
	local player = Players:GetPlayerByUserId(playerUserId)
	if not player then return false, "NotAlive" end
	local character = player.Character
	local members0, members1 = WeldServer.GetAssemblyTargets(a), WeldServer.GetAssemblyTargets(b)
	if table.find(members0, b) then return false, "AlreadyWelded" end
	local release = reserveGroups(a, b)
	if not release then return false, "Busy" end
	local function check(): boolean
		local root = InteractionCharacter.getRoot(player)
		if player.Parent ~= Players or player.Character ~= character or not root
			or not validPair(a,b) or graph:HasEdge(a,b) or not HingeGeometry.ready(endpoint0,endpoint1,hingeConfig)
			or not WeldServer.IsSameAssembly(a,members0) or not WeldServer.IsSameAssembly(b,members1)
			or (contextCheck and not contextCheck()) then return false end
		local point0, point1 = HingeGeometry.world(endpoint0), HingeGeometry.world(endpoint1)
		return (root.Position-point0).Magnitude <= config.MAX_USE_DISTANCE and (root.Position-point1).Magnitude <= config.MAX_USE_DISTANCE
			and InteractionVisibility.canSee(player,point0,{a,b}) and InteractionVisibility.canSee(player,point1,{a,b})
	end
	local ok, allowed, reason = pcall(function(): (boolean,string)
		if not check() then return false, "NotReady" end
		if not validators:Check(a,b,playerUserId) then return false, "Denied" end
		if not check() then return false, "NotReady" end
		local point0, point1 = HingeGeometry.world(endpoint0), HingeGeometry.world(endpoint1)
		createRecord(a,b,{part0=endpoint0.part,part1=endpoint1.part,point0=point0,point1=point1,distance=(point0-point1).Magnitude},
			if kind == "Hinge" then {endpoint0,endpoint1} else nil, nil, hingeConfig)
		return true, if kind == "Hinge" then "Hinged" else "Mounted"
	end)
	release()
	if not ok then warn("WeldSystem: point connection failed:", allowed); return false,"Failed" end
	return allowed,reason
end

-- Without an actor, trusted server scripts skip character/reach/visibility checks.
function WeldServer.Weld(a: Target, b: Target, playerUserId: number?, contextCheck: (() -> (boolean, string?))?, selection: MarkerPoint?): (boolean, string)
	prune()
	if not validPair(a, b) then return false, "InvalidTarget" end
	if graph:HasEdge(a, b) then return false, "AlreadyWelded" end
	local player = if playerUserId ~= nil then Players:GetPlayerByUserId(playerUserId) else nil
	if playerUserId ~= nil and not player then return false, "OutOfReach" end
	local character = if player then player.Character else nil
	local function actorCheck(contact: WeldGeometry.Contact): (boolean, string?)
		local point = if selection then markerPosition(a, selection) else nil
		if selection and not point then return false, "InvalidTarget" end
		if not player then return true, nil end
		if player.Character ~= character or not InteractionCharacter.getRoot(player) then return false, "NotAlive" end
		if point then
			if (InteractionCharacter.getRoot(player).Position - point).Magnitude > config.MAX_USE_DISTANCE then return false, "OutOfReach" end
			if not InteractionVisibility.canSee(player, point, {a, b}) then return false, "NotVisible" end
		end
		if not inReach(player, contact) then return false, "OutOfReach" end
		if not InteractionVisibility.canSee(player, contact.point0, {a, b})
			or not InteractionVisibility.canSee(player, contact.point1, {a, b}) then return false, "NotVisible" end
		return true, nil
	end
	local release = reserveGroups(a, b)
	if not release then return false, "Busy" end
	local succeeded, allowed, reason = pcall(function(): (boolean, string)
		local contact = getContact(a, b)
		if not contact or contact.distance > config.MAX_WELD_DISTANCE then return false, "TooFar" end
		local validActor, actorReason = actorCheck(contact)
		if not validActor then return false, actorReason :: string end
		if not validators:Check(a, b, playerUserId) then return false, "Denied" end
		-- Validators may yield, so recheck before changing the scene.
		if not validPair(a, b) or graph:HasEdge(a, b) or (player and player.Parent ~= Players) then
			return false, "InvalidTarget"
		end
		if contextCheck then
			local validContext, contextReason = contextCheck()
			if not validContext then return false, contextReason or "EquipTool" end
		end
		contact = getContact(a, b)
		if not contact or contact.distance > config.MAX_WELD_DISTANCE then return false, "TooFar" end
		validActor, actorReason = actorCheck(contact)
		if not validActor then return false, actorReason :: string end
		createRecord(a, b, contact, nil, selection)
		return true, "Welded"
	end)
	release()
	if not succeeded then warn("WeldSystem: weld creation failed:", allowed); return false, "Failed" end
	return allowed, reason
end

function WeldServer.TryWeld(a: Target, b: Target, playerUserId: number): (boolean, string)
	return WeldServer.Weld(a, b, playerUserId)
end

function WeldServer.Unweld(a: Target, b: Target, playerUserId: number?, contextCheck: (() -> (boolean, string?))?): (boolean, string)
	local record = findRecord(a, b)
	if not record then return false, "NotWelded" end
	local player = if playerUserId ~= nil then Players:GetPlayerByUserId(playerUserId) else nil
	if playerUserId ~= nil and not player then return false, "OutOfReach" end
	local release = reserveGroups(a, b)
	if not release then return false, "Busy" end
	local character = if player then player.Character else nil
	local function actorCheck(): (boolean, string?)
		if not player then return true, nil end
		local root = InteractionCharacter.getRoot(player)
		if player.Character ~= character or not root then return false, "NotAlive" end
		if player.Parent ~= Players or (root.Position - record.marker.Position).Magnitude > config.MAX_USE_DISTANCE then return false, "OutOfReach" end
		if not InteractionVisibility.canSee(player, record.marker.Position, {a, b}) then return false, "NotVisible" end
		return true, nil
	end
	local succeeded, allowed, reason = pcall(function(): (boolean, string)
		local validActor, actorReason = actorCheck()
		if not validActor then return false, actorReason :: string end
		if not unweldValidators:Check(a, b, playerUserId) then return false, "Denied" end
		-- The exact record must survive a yielding condition; never remove a replacement weld.
		if not records[record] or not isRecordValid(record) then return false, "NotWelded" end
		if contextCheck then
			local validContext, contextReason = contextCheck()
			if not validContext then return false, contextReason or "EquipTool" end
		end
		validActor, actorReason = actorCheck()
		if not validActor then return false, actorReason :: string end
		removeRecord(record)
		return true, "Unwelded"
	end)
	release()
	if not succeeded then warn("UnweldSystem: removal failed:", allowed); return false, "Failed" end
	return allowed, reason
end

function WeldServer.UnweldMarker(marker: any, playerUserId: number, contextCheck: (() -> (boolean, string?))?): (boolean, string)
	local a, b = WeldServer.GetWeldTargets(marker)
	if not a or not b then return false, "InvalidMarker" end
	return WeldServer.Unweld(a, b, playerUserId, contextCheck)
end

function WeldServer.WeldNearest(target: Target, playerUserId: number, contextCheck: (() -> (boolean, string?))?, selection: MarkerPoint?): (boolean, string, Target?)
	local player = Players:GetPlayerByUserId(playerUserId)
	if not player or not InteractionCharacter.getRoot(player) then return false, "NotAlive" end
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
	local allowed, reason = WeldServer.Weld(target, nearest, playerUserId, contextCheck, selection)
	return allowed, reason, nearest
end

return table.freeze(WeldServer)
