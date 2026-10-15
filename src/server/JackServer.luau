local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local shared = ReplicatedStorage.Shared
local config = require(shared.JackConfig)
local weldConfig = require(shared.WeldConfig)
local ObjectTargets = require(shared.ObjectTargets)
local ObjectMechanisms = require(shared.ObjectMechanisms)
local InteractionCharacter = require(shared.InteractionCharacter)
local InteractionVisibility = require(shared.InteractionVisibility)
local RequestLimiter = require(shared.RequestLimiter)
local ValidationRegistry = require(shared.ValidationRegistry)
local JackMotion = require(shared.JackMotion)
local JackCollision = require(shared.JackCollision)
local WeldServer = require(script.Parent.WeldServer)
local DragServer = require(script.Parent.DragServer)
local FreezeServer = require(script.Parent.FreezeServer)
local ServerOwnership = require(script.Parent.ServerOwnership)
local JackVisual = require(script.Parent.JackVisual)
local locks = require(script.Parent.InteractionLocks)

type Target = ObjectTargets.Target
type Record = {
	target: Target, owner: Player, character: Model, model: Model,
	base: Vector3, floor: BasePart | Terrain, floorFrame: CFrame?,
	height: number, goal: number, removing: boolean,
	parts: {[BasePart]: boolean}, connections: {RBXScriptConnection},
}
local JackServer = {}
local records: {[Record]: boolean} = {}
local byPart: {[BasePart]: Record} = {}
local byModel: {[Model]: Record} = {}
local byPlayer: {[Player]: Record} = {}
local pending: {[Player]: boolean} = {}
local limiter = RequestLimiter.new()
local validators = ValidationRegistry.new("JackSystem", warn)
local folder = Instance.new("Folder")
folder.Name, folder.Parent = "VehicleJacks", workspace

local function findJack(hit: any): Record?
	if typeof(hit) ~= "Instance" then return nil end
	local current = hit
	while current and current ~= workspace do
		if byModel[current] then return byModel[current] end
		current = current.Parent
	end
	return nil
end

-- Consult the current graph too: a newly welded wheel is protected before the next simulation tick.
local function supports(target: Target): {[Record]: boolean}
	local result = {}
	for _, part in ObjectTargets.getParts(WeldServer.GetAssemblyTargets(target)) do
		local record = byPart[part]
		if record then result[record] = true end
	end
	return result
end

function JackServer.IsSupported(target: Instance): boolean
	if not ObjectTargets.isSupported(target) then return false end
	return next(supports(target :: Target)) ~= nil
end

function JackServer.GetJack(target: Instance): Model?
	if not ObjectTargets.isSupported(target) then return nil end
	local record = next(supports(target :: Target))
	return if record then record.model else nil
end

function JackServer.RegisterJackValidator(callback: (Target, number) -> boolean): () -> ()
	return validators:Register(callback)
end

local function stop(part: BasePart)
	part.AssemblyLinearVelocity, part.AssemblyAngularVelocity = Vector3.zero, Vector3.zero
end

local function restore(part: BasePart, anchored: boolean)
	if part.Parent then stop(part); part.Anchored = anchored end
end

local function release(record: Record, visualBeingDestroyed: boolean?)
	if not records[record] then return end
	records[record], byModel[record.model] = nil, nil
	if byPlayer[record.owner] == record then byPlayer[record.owner] = nil end
	for _, connection in record.connections do connection:Disconnect() end
	local parts = {}
	for part, anchored in record.parts do
		if byPart[part] == record then byPart[part] = nil end
		restore(part, anchored)
		table.insert(parts, part)
	end
	ServerOwnership.Claim(parts)
	if not visualBeingDestroyed then record.model:Destroy() end
end

local function groupParts(members: {Target}, allowOccupants: boolean?): {BasePart}?
	local parts = ObjectTargets.getParts(members)
	if #parts == 0 or #parts > config.MAX_GROUP_PARTS then return nil end
	for _, member in members do
		if not ObjectTargets.isSupported(member) or (not allowOccupants and ObjectMechanisms.hasOccupant(member)) then return nil end
		local ancestor: Instance? = member
		while ancestor and ancestor ~= workspace do
			if ancestor:IsA("Model") and ancestor:FindFirstChildWhichIsA("Humanoid") then return nil end
			ancestor = ancestor.Parent
		end
	end
	local own = {}
	for _, part in parts do
		if not part:IsDescendantOf(workspace) or not ObjectTargets.isFiniteCFrame(part.CFrame)
			or not ObjectTargets.isFiniteVector(part.Size) then return nil end
		own[part] = true
	end
	-- Native joints to the map or unrelated objects must not move with the jack.
	for _, part in parts do
		for _, connected in part:GetConnectedParts(true) do
			if not own[connected] and connected:GetAttribute(weldConfig.MARKER_ATTRIBUTE) ~= true then return nil end
		end
	end
	local minimum, maximum = JackMotion.bounds(parts)
	local size = maximum - minimum
	if math.max(size.X, size.Y, size.Z) > config.MAX_GROUP_EXTENT then return nil end
	return parts
end

local function synchronize(record: Record): (boolean, string?)
	local members = WeldServer.GetAssemblyTargets(record.target)
	local parts = groupParts(members, true)
	if not parts then return false, "InvalidTarget" end
	local keys = ObjectTargets.getLockKeys(members, parts)
	for part in record.parts do table.insert(keys, part) end
	local unlock = locks:TryAcquire(keys)
	if not unlock then return false, "Busy" end
	for _, part in parts do
		if byPart[part] and byPart[part] ~= record then unlock(); return false, "Busy" end
	end
	FreezeServer.UnfreezeMembers(members, "Jacked")
	local current = {}
	for _, part in parts do
		current[part] = true
		if record.parts[part] == nil then record.parts[part] = part.Anchored end
		byPart[part] = record
		stop(part)
		part.Anchored = true
	end
	local detached = {}
	for part, anchored in record.parts do
		if not current[part] then
			record.parts[part], byPart[part] = nil, nil
			restore(part, anchored)
			table.insert(detached, part)
		end
	end
	ServerOwnership.Claim(detached)
	unlock()
	return true, nil
end

local function actorCheck(player: Player, point: Vector3, targets: {Instance}): (boolean, string)
	local root = InteractionCharacter.getRoot(player)
	if player.Parent ~= Players or not root then return false, "NotAlive" end
	if (root.Position - point).Magnitude > config.MAX_USE_DISTANCE then return false, "OutOfReach" end
	if not InteractionVisibility.canSee(player, point, targets) then return false, "NotVisible" end
	return true, "Ready"
end

function JackServer.HandleControl(player: Player, model: any, action: any): (boolean, string)
	if not limiter:TryTake(player, config.REQUEST_RATE, config.REQUEST_BURST) then return false, "Busy" end
	local record = findJack(model)
	if not record or record.model ~= model then return false, "InvalidTarget" end
	if record.owner ~= player then return false, "NotOwner" end
	local visibleTargets: {Instance} = WeldServer.GetAssemblyTargets(record.target) :: {Instance}
	table.insert(visibleTargets, record.model)
	local valid, reason = actorCheck(player, record.base + Vector3.new(0, 0.4, 0), visibleTargets)
	if not valid then return false, reason end
	if player.Character ~= record.character then return false, "NotAlive" end
	if action == "Remove" then
		record.removing, record.goal = true, 0
		return true, "Lowering"
	end
	if record.removing then return false, "Lowering" end
	if action ~= "Raise" and action ~= "Lower" then return false, "InvalidAction" end
	record.goal = math.clamp(record.goal + (if action == "Raise" then config.HEIGHT_STEP else -config.HEIGHT_STEP), 0, config.MAX_HEIGHT)
	return true, "Adjusted"
end

local function equipped(player: Player): boolean
	local tool = player.Character and player.Character:FindFirstChild(config.TOOL_NAME)
	return tool ~= nil and tool:IsA("Tool") and tool.Enabled
end

local function ground(target: Target, members: {Target}): (RaycastResult?, number?, string?)
	local minimum, maximum = JackMotion.bounds(ObjectTargets.getParts({target}))
	local center = (minimum + maximum) * 0.5
	-- Begin above the target so a small floor overlap cannot put the ray inside
	-- the floor, where a downward ray would miss its top surface.
	local origin = Vector3.new(center.X, maximum.Y + 0.25, center.Z)
	local direction = Vector3.new(0, minimum.Y - config.MAX_SETUP_GAP - origin.Y, 0)
	local excluded: {Instance} = table.clone(members) :: {Instance}
	table.insert(excluded, folder)
	for _, player in Players:GetPlayers() do if player.Character then table.insert(excluded, player.Character) end end
	local params = RaycastParams.new()
	params.FilterType, params.FilterDescendantsInstances = Enum.RaycastFilterType.Exclude, excluded
	params.RespectCanCollide, params.IgnoreWater = true, true
	for _ = 1, config.MAX_GROUND_RAY_HITS do
		local hit = workspace:Raycast(origin, direction, params)
		if not hit or not ObjectTargets.isFiniteVector(hit.Position) or not ObjectTargets.isFiniteVector(hit.Normal) then return nil, nil, "NoGround" end
		if hit.Instance:IsA("Terrain") or (hit.Instance:IsA("BasePart") and hit.Instance.Anchored) then
			local height = minimum.Y - hit.Position.Y
			if hit.Normal.Y < config.MIN_GROUND_NORMAL_Y then return nil, nil, "UnevenGround" end
			if height < -config.GROUND_CONTACT_TOLERANCE then return nil, nil, "GroundBlocked" end
			if height > config.MAX_SETUP_GAP then return nil, nil, "NoGround" end
			return hit, math.max(height, 0), nil
		end
		-- A loose wheel or seat is not a foundation, but does not hide the real floor.
		table.insert(excluded, hit.Instance)
		params.FilterDescendantsInstances = excluded
	end
	return nil, nil, "GroundObstructed"
end

function JackServer.Place(player: Player, hit: any, point: any): (boolean, string)
	if pending[player] then return false, "Busy" end
	-- A tool click on an existing jack also lowers/removes it.
	local existing = findJack(hit)
	if existing then
		if not equipped(player) then return false, "EquipTool" end
		return JackServer.HandleControl(player, existing.model, "Remove")
	end
	if not limiter:TryTake(player, config.REQUEST_RATE, config.REQUEST_BURST) then return false, "Busy" end
	if not InteractionCharacter.getRoot(player) then return false, "NotAlive" end
	if not equipped(player) then return false, "EquipTool" end
	if byPlayer[player] then return false, "AlreadyPlaced" end
	if typeof(hit) ~= "Instance" or typeof(point) ~= "Vector3" or not ObjectTargets.isFiniteVector(point) then return false, "InvalidTarget" end
	local target = ObjectTargets.findTagged(hit, config.TARGET_TAG)
	if not target or not ObjectTargets.containsPoint(target, point) then return false, "InvalidTarget" end
	local members = WeldServer.GetAssemblyTargets(target)
	local parts = groupParts(members)
	if not parts then return false, "InvalidTarget" end
	if next(supports(target)) then return false, "Busy" end
	local validActor, actorReason = actorCheck(player, point, members)
	if not validActor then return false, actorReason end
	local unlock = locks:TryAcquire(ObjectTargets.getLockKeys(members, parts))
	if not unlock then return false, "Busy" end
	local character = player.Character
	pending[player] = true
	local created: Record? = nil
	local ok, allowed, reason = pcall(function(): (boolean, string)
		for _, member in members do
			if not DragServer.CanGrab(member, player.UserId) or not validators:Check(member, player.UserId) then return false, "Denied" end
		end
		local liveParts = groupParts(members)
		if player.Character ~= character or not liveParts or #liveParts ~= #parts
			or not WeldServer.IsSameAssembly(target, members) or not CollectionService:HasTag(target, config.TARGET_TAG)
			or not ObjectTargets.containsPoint(target, point) then return false, "InvalidTarget" end
		local expected = {}; for _, part in parts do expected[part] = true end
		for _, part in liveParts do if not expected[part] then return false, "InvalidTarget" end end
		if not equipped(player) then return false, "EquipTool" end
		local valid, actorReason = actorCheck(player, point, members)
		if not valid then return false, actorReason end
		local count = 0; for _ in records do count += 1 end
		if byPlayer[player] or count >= config.MAX_ACTIVE_JACKS then return false, "Limit" end
		local floorHit, height, groundReason = ground(target, members)
		if not floorHit or not height then return false, groundReason or "NoGround" end
		local model, connections = JackVisual.Create(folder, player.UserId, floorHit.Position, height, JackServer.HandleControl)
		local record: Record = {target = target, owner = player, character = character, model = model,
			base = floorHit.Position, floor = floorHit.Instance,
			floorFrame = if floorHit.Instance:IsA("BasePart") then floorHit.Instance.CFrame else nil,
			height = height, goal = math.min(height + config.DEFAULT_LIFT, config.MAX_HEIGHT),
			removing = false, parts = {}, connections = connections}
		created = record
		records[record], byPlayer[player], byModel[model] = true, record, record
		FreezeServer.UnfreezeMembers(members, "Jacked")
		for _, part in parts do
			record.parts[part], byPart[part] = part.Anchored, record
			stop(part); part.Anchored = true
		end
		table.insert(connections, model.Destroying:Connect(function() release(record, true) end))
		return true, "Placed"
	end)
	pending[player] = nil
	unlock()
	if not ok then
		if created then release(created) end
		warn("JackSystem: placement failed:", allowed)
		return false, "Failed"
	end
	return allowed, reason
end

-- Resolve movement for the current parts, excluding only this assembly and service markers.
local function travel(record: Record, distance: number): (number, boolean)
	local excluded: {Instance} = {folder}
	local welds = workspace:FindFirstChild("WeldConnections")
	if welds then table.insert(excluded, welds) end
	local parts = {}
	for part in record.parts do
		table.insert(excluded, part)
		table.insert(parts, part)
	end
	return JackCollision.travel(parts, excluded, distance)
end

function JackServer.Step(dt: number)
	for record in table.clone(records) do
		local root = InteractionCharacter.getRoot(record.owner)
		local floorValid = record.floor:IsDescendantOf(workspace)
			and (record.floor:IsA("Terrain") or (record.floor.Anchored and record.floor.CFrame == record.floorFrame))
		if record.owner.Parent ~= Players or record.owner.Character ~= record.character or not root
			or not floorValid or not record.model:IsDescendantOf(folder)
			or not ObjectTargets.isSupported(record.target) or not CollectionService:HasTag(record.target, config.TARGET_TAG) then
			release(record); continue
		end
		local synced, reason = synchronize(record)
		if not synced then
			if reason ~= "Busy" then release(record) end
			continue
		end
		local nextHeight = JackMotion.advance(record.height, record.goal, dt, config)
		local distance = nextHeight - record.height
		local grounded = false
		if math.abs(distance) > 0.000001 then
			local ok, resolved, onGround = pcall(travel, record, distance)
			if not ok then
				release(record)
				warn("JackSystem: movement failed; support released:", resolved)
				continue
			end
			distance, grounded = resolved, onGround
			local translation = CFrame.new(0, distance, 0)
			for part in record.parts do part.CFrame = translation * part.CFrame end
			record.height += distance
		end
		-- Do not keep an unreachable lower goal after F hits the floor: R should lift
		-- from the actual supported height, rather than consume presses below it.
		if grounded and not record.removing then record.goal = record.height end
		JackVisual.Update(record.model, record.base, record.height, record.removing)
		if record.removing and (grounded or record.height < 0.01) then release(record) end
	end
end

function JackServer.RemovePlayer(player: Player)
	local record = byPlayer[player]
	if record then release(record) end
	limiter:Remove(player)
end

DragServer.RegisterGrabValidator(function(target) return not JackServer.IsSupported(target) end)
FreezeServer.RegisterFreezeValidator(function(target) return not JackServer.IsSupported(target) end)
WeldServer.RegisterWeldValidator(function(a, b)
	local combined = supports(a)
	for record in supports(b) do combined[record] = true end
	local count = 0; for _ in combined do count += 1 end
	if count == 0 then return true end
	if count > 1 then return false end
	local members = WeldServer.GetAssemblyTargets(a)
	for _, member in WeldServer.GetAssemblyTargets(b) do table.insert(members, member) end
	return groupParts(members) ~= nil
end)

return table.freeze(JackServer)
