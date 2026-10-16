-- Two-click selection, finite physical attraction, then a settled permanent connection.
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local shared = ReplicatedStorage.Shared
local config = require(shared.HingeConfig)
local dragConfig = require(shared.DragConfig)
local ObjectTargets = require(shared.ObjectTargets)
local ObjectMechanisms = require(shared.ObjectMechanisms)
local Geometry = require(shared.HingeGeometry)
local Bounds = require(shared.JackMotion)
local InteractionCharacter = require(shared.InteractionCharacter)
local Visibility = require(shared.InteractionVisibility)
local RequestLimiter = require(shared.RequestLimiter)
local ValidationRegistry = require(shared.ValidationRegistry)
local WeldServer = require(script.Parent.WeldServer)
local DragServer = require(script.Parent.DragServer)
local FreezeServer = require(script.Parent.FreezeServer)
local JackServer = require(script.Parent.JackServer)
local Ownership = require(script.Parent.ServerOwnership)
local locks = require(script.Parent.InteractionLocks)

local HingeServer = {}
local selected, jobs = {}, {}
local nextId = 0
local limiter = RequestLimiter.new()
local validators = ValidationRegistry.new("HingeTool", warn)
local changed = Instance.new("BindableEvent")
HingeServer.Changed = changed.Event

local function equipped(player: Player): boolean
	local tool = player.Character and player.Character:FindFirstChild(config.TOOL_NAME)
	return player.Parent == Players and InteractionCharacter.getRoot(player) ~= nil
		and tool ~= nil and tool:IsA("Tool") and tool.Enabled
end

local function pointCheck(player: Player, endpoint, visible): (boolean, string)
	if not Geometry.valid(endpoint) or not CollectionService:HasTag(endpoint.target,config.TAG_NAME) then return false,"InvalidTarget" end
	local root = InteractionCharacter.getRoot(player)
	if not root then return false,"NotAlive" end
	local point = Geometry.world(endpoint)
	if (root.Position-point).Magnitude > config.MAX_USE_DISTANCE then return false,"OutOfReach" end
	if not Visibility.canSee(player,point,visible) then return false,"NotVisible" end
	return true,"Ready"
end

local function pick(hit, point, normal)
	if not ObjectTargets.isSupported(hit) or not hit:IsA("BasePart") or typeof(point) ~= "Vector3"
		or typeof(normal) ~= "Vector3" or not ObjectTargets.isFiniteVector(point) or not ObjectTargets.isFiniteVector(normal)
		or math.abs(normal.Magnitude-1) > 0.01 or not ObjectTargets.isFiniteCFrame(hit.CFrame)
		or (hit:GetClosestPointOnSurface(point)-point).Magnitude > config.SURFACE_TOLERANCE then return nil end
	local target = ObjectTargets.findTagged(hit,config.TAG_NAME)
	if not target then return nil end
	local part = hit
	if ObjectMechanisms.isPreserved(target) then
		part = target.PrimaryPart
		if not part or not part:IsDescendantOf(target) then return nil end
		point = part:GetClosestPointOnSurface(point)
		normal = part.CFrame.XVector
	elseif part:IsA("Part") and part.Shape == Enum.PartType.Cylinder then
		local axle = part.CFrame.XVector
		normal = if axle:Dot(normal) < 0 then -axle else axle
	end
	return {target=target, part=part, point=part.CFrame:PointToObjectSpace(point),
		axis=part.CFrame.Rotation:Inverse():PointToWorldSpace(normal)}
end

local function retargetMount(endpoint, otherPoint)
	if ObjectMechanisms.isPreserved(endpoint.target) then
		-- A prepared wheel already owns its axle. Pull its mounting face, not its tire.
		endpoint.point = endpoint.part.CFrame:PointToObjectSpace(endpoint.part:GetClosestPointOnSurface(otherPoint))
		local toward = endpoint.part.CFrame:PointToObjectSpace(otherPoint)
		endpoint.axis = Vector3.new(if toward.X < 0 then -1 else 1,0,0)
	end
end

local function group(target)
	local members = WeldServer.GetAssemblyTargets(target)
	local parts = ObjectTargets.getParts(members)
	if #parts == 0 or #parts > config.MAX_GROUP_PARTS then return nil end
	local minimum, maximum = Bounds.bounds(parts)
	local size = maximum-minimum
	if math.max(size.X,size.Y,size.Z) > config.MAX_GROUP_EXTENT then return nil end
	local own, fixed = {}, JackServer.IsSupported(target)
	for _, part in parts do
		if not ObjectTargets.isFiniteCFrame(part.CFrame) then return nil end
		own[part] = true
		if part.Anchored and not FreezeServer.IsFrozen(part) then fixed = true end
	end
	for _, member in members do
		if ObjectMechanisms.hasOccupant(member) then return nil end
		local current = member
		while current and current ~= workspace do
			if current:IsA("Model") and current:FindFirstChildWhichIsA("Humanoid") then return nil end
			current = current.Parent
		end
	end
	for _, part in parts do
		for _, linked in part:GetConnectedParts(true) do
			if not own[linked] and linked:GetAttribute("WeldMarker") ~= true then return nil end
		end
	end
	return {target=target,members=members,parts=parts,fixed=fixed}
end

local function sameGroup(snapshot): boolean
	if not WeldServer.IsSameAssembly(snapshot.target,snapshot.members) then return false end
	local current = ObjectTargets.getParts(snapshot.members)
	if #current ~= #snapshot.parts then return false end
	local expected = {}; for _, part in snapshot.parts do expected[part] = true end
	for _, part in current do
		if not expected[part] or not part:IsDescendantOf(workspace) or not ObjectTargets.isFiniteCFrame(part.CFrame) then return false end
	end
	return true
end

local function cleanup(job)
	if job.cleaned then return end
	job.cleaned = true
	if jobs[job.player] == job then jobs[job.player] = nil end
	if job.release then job.release() end
	for _, instance in job.instances do instance:Destroy() end
	for _, snapshot in {job.group0,job.group1} do
		for _, part in snapshot.parts do
			if part.Parent and not part.Anchored then
				part.AssemblyLinearVelocity, part.AssemblyAngularVelocity = Vector3.zero, Vector3.zero
			end
		end
		Ownership.Claim(snapshot.parts)
	end
end

local function finish(job, reason)
	cleanup(job)
	changed:Fire(job.player,job.id,reason)
end

function HingeServer.Cancel(player: Player)
	selected[player] = nil
	local job = jobs[player]
	if job then finish(job,"Cancelled") end
end

function HingeServer.RemovePlayer(player: Player)
	HingeServer.Cancel(player)
	limiter:Remove(player)
end

function HingeServer.RegisterPullValidator(callback): () -> ()
	return validators:Register(callback)
end

local function context(job): (boolean, string)
	local player = job.player
	if jobs[player] ~= job or job.cleaned then return false,"Cancelled" end
	if player.Character ~= job.character or not equipped(player) then return false,"Cancelled" end
	if not sameGroup(job.group0) or not sameGroup(job.group1) then return false,"Changed" end
	for _, snapshot in {job.group0,job.group1} do
		local anchored = false
		for _, part in snapshot.parts do
			if part.Anchored and not FreezeServer.IsFrozen(part) then anchored = true end
		end
		if anchored ~= snapshot.fixed then return false,"Changed" end
	end
	local visible = table.clone(job.group0.members)
	for _, member in job.group1.members do table.insert(visible,member) end
	for _, endpoint in {job.a,job.b} do
		local allowed, reason = pointCheck(player,endpoint,visible)
		if not allowed then return false,reason end
	end
	for part, initial in job.initialPositions do
		if (part.Position-initial).Magnitude > job.maxTravel then return false,"MovedTooFar" end
	end
	return true,"Ready"
end

local function prepare(job)
	for _, snapshot in {job.group0,job.group1} do
		if not snapshot.fixed and not CollectionService:HasTag(snapshot.target,dragConfig.TAG_NAME) then return false end
		for _, member in snapshot.members do
			if not snapshot.fixed and ((dragConfig.REQUIRE_ALL_MEMBERS_DRAGGABLE and not CollectionService:HasTag(member,dragConfig.TAG_NAME))
				or not DragServer.CanGrab(member,job.player.UserId)) then return false end
			if not context(job) then return false end
		end
	end
	for _, snapshot in {job.group0,job.group1} do
		if not snapshot.fixed then FreezeServer.UnfreezeMembers(snapshot.members,"PointPull") end
		if not context(job) then return false end
		for _, member in snapshot.members do
			if member:IsA("Model") and not ObjectMechanisms.isPreserved(member) and not member:FindFirstChild("WeldObjectRig") then
				local parts = ObjectTargets.getParts({member})
				local root = if member.PrimaryPart and member.PrimaryPart:IsDescendantOf(member) then member.PrimaryPart else parts[1]
				local container = Instance.new("Folder")
				table.insert(job.instances,container)
				container.Name, container.Parent = "HingePullRig", member
				for _, part in parts do
					if part ~= root then
						local weld = Instance.new("WeldConstraint")
						weld.Part0, weld.Part1, weld.Parent = root,part,container
					end
				end
			end
		end
		if not Ownership.Claim(snapshot.parts) then return false end
	end
	return true
end

local function attraction(job)
	local attachments = {}
	for _, endpoint in {job.a,job.b} do
		local attachment = Instance.new("Attachment")
		table.insert(job.instances,attachment)
		attachment.Name, attachment.Position, attachment.Axis = "HingePullPoint",endpoint.point,endpoint.axis
		attachment.SecondaryAxis, attachment.Parent = Geometry.secondary(endpoint.axis),endpoint.part
		table.insert(attachments,attachment)
	end
	local position = Instance.new("AlignPosition")
	table.insert(job.instances,position)
	position.Name, position.Mode = "HingePullPosition",Enum.PositionAlignmentMode.TwoAttachment
	position.Attachment0, position.Attachment1 = attachments[1],attachments[2]
	position.RigidityEnabled, position.ReactionForceEnabled, position.ApplyAtCenterOfMass = false,true,false
	position.ForceLimitMode = Enum.ForceLimitMode.Magnitude
	position.MaxForce, position.MaxVelocity, position.Responsiveness = job.settings.force,job.settings.speed,config.RESPONSIVENESS
	position.Parent = job.a.part
	local orientation = Instance.new("AlignOrientation")
	table.insert(job.instances,orientation)
	orientation.Name, orientation.Mode = "HingePullOrientation",Enum.OrientationAlignmentMode.TwoAttachment
	orientation.Attachment0, orientation.Attachment1 = attachments[1],attachments[2]
	orientation.AlignType = Enum.AlignType.AllAxes
	orientation.RigidityEnabled, orientation.ReactionTorqueEnabled = false,true
	orientation.MaxTorque, orientation.MaxAngularVelocity = job.settings.torque,job.settings.angularSpeed
	orientation.Responsiveness, orientation.Parent = config.RESPONSIVENESS,job.a.part
	job.position, job.orientation = position,orientation
end

function HingeServer.Click(player: Player, hit: any, point: any, normal: any): (boolean,string,any?)
	if not limiter:TryTake(player,config.REQUEST_RATE,config.REQUEST_BURST) then return false,"Busy",nil end
	if jobs[player] then return false,"Busy",nil end
	if not equipped(player) then return false,"EquipTool",nil end
	local endpoint = pick(hit,point,normal)
	if not endpoint then return false,"InvalidTarget",nil end
	local valid, reason = pointCheck(player,endpoint,{endpoint.target})
	if not valid then return false,reason,nil end
	local choice = selected[player]
	if not choice or choice.character ~= player.Character or os.clock()-choice.time > config.SELECTION_TIMEOUT then
		nextId += 1
		selected[player] = {endpoint=endpoint,character=player.Character,time=os.clock(),id=nextId}
		return true,"Selected",{id=nextId,part=endpoint.part,point=endpoint.point}
	end
	local a, b = table.clone(choice.endpoint),endpoint
	if not Geometry.valid(a) then selected[player] = nil; return false,"Changed",nil end
	if a.target == b.target then return false,"SameTarget",nil end
	local group0, group1 = group(a.target),group(b.target)
	if not group0 or not group1 then return false,"InvalidTarget",nil end
	if table.find(group0.members,b.target) then return false,"AlreadyConnected",nil end
	local sharedParts = {}; for _, part in group0.parts do sharedParts[part] = true end
	for _, part in group1.parts do if sharedParts[part] then return false,"AlreadyConnected",nil end end
	if group0.fixed and group1.fixed then return false,"BothFixed",nil end
	retargetMount(a,Geometry.world(b)); retargetMount(b,Geometry.world(a))
	local point0, point1 = Geometry.world(a),Geometry.world(b)
	-- Surfaces must face each other, while the two attachment X axes point the same
	-- way. This keeps the tire outside the platform instead of pulling it inside.
	b.axis = -b.axis
	local settings = Geometry.settings(config)
	if settings.power <= 0 then return false,"Disabled",nil end
	if (point0-point1).Magnitude > settings.distance then return false,"TooFar",nil end
	local count = 0; for _ in jobs do count += 1 end
	if count >= config.MAX_ACTIVE_PULLS then return false,"Busy",nil end
	local keys = ObjectTargets.getLockKeys(group0.members,group0.parts)
	for _, key in ObjectTargets.getLockKeys(group1.members,group1.parts) do table.insert(keys,key) end
	local release = locks:TryAcquire(keys)
	if not release then return false,"Busy",nil end
	nextId += 1
	local job = {id=nextId,player=player,character=player.Character,a=a,b=b,group0=group0,group1=group1,release=release,
		instances={},initialPositions={},settings=settings,maxTravel=math.max(settings.distance*2,0.1),phase="Preparing",start=os.clock()}
	for _, snapshot in {group0,group1} do for _, part in snapshot.parts do job.initialPositions[part] = part.Position end end
	jobs[player], selected[player] = job,nil
	local ok, allowed, problem = pcall(function()
		if not validators:Check(a.target,b.target,player.UserId) or not WeldServer.CheckConnectionConditions(a.target,b.target,player.UserId) then return false,"Denied" end
		local active, why = context(job)
		if not active then return false,why end
		if not prepare(job) then return false,"Denied" end
		active, why = context(job)
		if not active then return false,why end
		attraction(job)
		job.phase, job.start = "Pulling",os.clock()
		return true,"Pulling"
	end)
	if not ok or not allowed then
		cleanup(job)
		if not ok then warn("HingeTool: setup failed:",allowed) end
		return false, if ok then problem else "Failed", {id=job.id}
	end
	return true,"Pulling",{id=job.id,part=a.part,point=a.point,part1=b.part,point1=b.point}
end

function HingeServer.Step()
	for _, player in Players:GetPlayers() do
		local choice = selected[player]
		if choice and (not equipped(player) or player.Character ~= choice.character or os.clock()-choice.time > config.SELECTION_TIMEOUT) then
			selected[player] = nil; changed:Fire(player,choice.id,"Cancelled")
		end
	end
	for _, job in table.clone(jobs) do
		if job.phase ~= "Pulling" then continue end
		local valid, reason = context(job)
		if not valid then finish(job,reason); continue end
		if os.clock()-job.start > config.PULL_TIMEOUT then finish(job,"TooWeak"); continue end
		if not Ownership.Claim(job.group0.parts) or not Ownership.Claim(job.group1.parts) then finish(job,"Failed"); continue end
		if not Geometry.ready(job.a,job.b,config) then job.settled = nil; continue end
		job.settled = job.settled or os.clock()
		if os.clock()-job.settled < config.SETTLE_TIME then continue end
		job.phase = "Finishing"
		job.position:Destroy(); job.orientation:Destroy()
		job.release()
		local kind = if ObjectMechanisms.isPreserved(job.a.target) or ObjectMechanisms.isPreserved(job.b.target) then "Weld" else "Hinge"
		local ok, allowed, result = pcall(function()
			if not validators:Check(job.a.target,job.b.target,job.player.UserId) then return false,"Denied" end
			if not context(job) then return false,"Cancelled" end
			return WeldServer.ConnectPoints(job.a,job.b,kind,job.player.UserId,function() return context(job) end)
		end)
		if not job.cleaned then finish(job, if ok and allowed then result else (if ok then result else "Failed")) end
	end
end

return table.freeze(HingeServer)
