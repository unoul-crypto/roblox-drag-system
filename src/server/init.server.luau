local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local config = require(ReplicatedStorage.Shared.DragConfig)
local dragCollision = require(ReplicatedStorage.Shared.DragCollision)
local dragWeight = require(ReplicatedStorage.Shared.DragWeight)
local dragAssembly = require(ReplicatedStorage.Shared.DragAssembly)
local objectTargets = require(ReplicatedStorage.Shared.ObjectTargets)
local dragServer = require(script.DragServer)
local weldServer = require(script.WeldServer)
local interactionLocks = require(script.InteractionLocks)

type DragTarget = BasePart | Model

type PartState = {
	part: BasePart,
	anchored: boolean,
}

type ModelRig = {
	model: Model?,
	root: BasePart,
	container: Folder,
	partStates: {PartState},
	originalPrimaryPart: BasePart?,
}

type CollisionState = {
	part: BasePart,
	canCollide: boolean,
}

type PhysicsDragRig = {
	root: BasePart,
	rootOffsetFromPivot: CFrame,
	container: Folder,
	attachment: Attachment,
	alignPosition: AlignPosition,
	alignOrientation: AlignOrientation,
	collisionStates: {CollisionState},
}

type DragSession = {
	id: number,
	target: DragTarget,
	members: {DragTarget},
	assembly: dragAssembly.Snapshot,
	release: () -> (),
	localGrabPoint: Vector3,
	rotation: CFrame,
	collisionMode: string,
	rotationMode: string,
	boxOffset: CFrame,
	boxSize: Vector3,
	lastPivot: CFrame,
	weight: number,
	dragVelocity: CFrame,
	lastUpdateAt: number,
	clientAuthoritative: boolean,
	modelRig: ModelRig?,
	physicsRig: PhysicsDragRig?,
}

type PendingRequest = {
	cancelled: boolean,
	release: (() -> ())?,
	modelRig: ModelRig?,
	physicsRig: PhysicsDragRig?,
}

local remotes = Instance.new("Folder")
remotes.Name = "DragRemotes"
remotes.Parent = ReplicatedStorage

local beginDragRemote = Instance.new("RemoteFunction")
beginDragRemote.Name = "BeginDrag"
beginDragRemote.Parent = remotes

local updateDragRemote = Instance.new("RemoteEvent")
updateDragRemote.Name = "UpdateDrag"
updateDragRemote.Parent = remotes

local endDragRemote = Instance.new("RemoteEvent")
endDragRemote.Name = "EndDrag"
endDragRemote.Parent = remotes

local dragEndedRemote = Instance.new("RemoteEvent")
dragEndedRemote.Name = "DragEnded"
dragEndedRemote.Parent = remotes

local sessionsByPlayer: {[Player]: DragSession} = {}
local ownerByTarget: {[Instance]: Player} = {}
local pendingByPlayer: {[Player]: PendingRequest} = {}
local nextSessionId = 0

local function getCharacterRoot(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end

	return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function isFiniteNumber(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function isFiniteVector(vector: Vector3): boolean
	return isFiniteNumber(vector.X) and isFiniteNumber(vector.Y) and isFiniteNumber(vector.Z)
end

local function isFiniteCFrame(cframe: CFrame): boolean
	return isFiniteVector(cframe.Position)
		and isFiniteVector(cframe.XVector)
		and isFiniteVector(cframe.YVector)
		and isFiniteVector(cframe.ZVector)
end

local function getCollisionMode(target: DragTarget): string
	local mode = target:GetAttribute(config.COLLISION_ATTRIBUTE)
	if mode == config.COLLISION_MODE_COLLIDE then
		return config.COLLISION_MODE_COLLIDE
	end
	if mode == config.COLLISION_MODE_NO_CLIP then
		return config.COLLISION_MODE_NO_CLIP
	end
	return config.DEFAULT_COLLISION_MODE
end

local function getRotationMode(target: DragTarget): string
	local mode = target:GetAttribute(config.ROTATION_ATTRIBUTE)
	if mode == config.ROTATION_MODE_CAMERA_RELATIVE then
		return config.ROTATION_MODE_CAMERA_RELATIVE
	end
	if mode == config.ROTATION_MODE_WORLD then
		return config.ROTATION_MODE_WORLD
	end
	return config.DEFAULT_ROTATION_MODE
end

local function getWeight(target: DragTarget): number
	return dragWeight.normalize(target:GetAttribute(config.WEIGHT_ATTRIBUTE))
end

local function shouldUsePhysics(weight: number): boolean
	return weight > 0 and config.WEIGHT_DRAG_MODE == config.WEIGHT_DRAG_MODE_PHYSICS
end

local function isValidTarget(target: any): boolean
	if typeof(target) ~= "Instance" or not target:IsDescendantOf(workspace) then
		return false
	end

	if not CollectionService:HasTag(target, config.TAG_NAME) then
		return false
	end

	if target:IsA("BasePart") then
		return true
	end

	return target:IsA("Model") and target:FindFirstChildWhichIsA("BasePart", true) ~= nil
end

local function isGroupDraggable(members: {DragTarget}): boolean
	if not config.REQUIRE_ALL_MEMBERS_DRAGGABLE then return true end
	for _, member in members do
		if not isValidTarget(member) then return false end
	end
	return true
end

local function getPreferredTarget(target: DragTarget): DragTarget
	return objectTargets.findTagged(target, config.TAG_NAME) or target
end

local function isPointInsideTarget(target: DragTarget, worldPoint: Vector3): boolean
	return objectTargets.containsPoint(target, worldPoint)
end

local function setNetworkOwner(parts: {BasePart}, owner: Player?, automatic: boolean?)
	local handledAssemblies: {[BasePart]: boolean} = {}

	for _, descendant in parts do
		if descendant:IsDescendantOf(workspace) and not descendant.Anchored then
			local assemblyRoot = descendant.AssemblyRootPart or descendant
			if not handledAssemblies[assemblyRoot] then
				handledAssemblies[assemblyRoot] = true
				local canSet = assemblyRoot:CanSetNetworkOwnership()
				if canSet then
					if owner then
						assemblyRoot:SetNetworkOwner(owner)
					elseif automatic then
						assemblyRoot:SetNetworkOwnershipAuto()
					else
						assemblyRoot:SetNetworkOwner(nil)
					end
				end
			end
		end
	end
end

local function isNetworkOwnedBy(parts: {BasePart}, player: Player): boolean
	local handledAssemblies: {[BasePart]: boolean} = {}
	local foundAssembly = false

	for _, descendant in parts do
		if descendant:IsA("BasePart") and not descendant.Anchored then
			local assemblyRoot = descendant.AssemblyRootPart or descendant
			if not handledAssemblies[assemblyRoot] then
				handledAssemblies[assemblyRoot] = true
				foundAssembly = true
				if assemblyRoot:GetNetworkOwner() ~= player then
					return false
				end
			end
		end
	end

	return foundAssembly
end

local function stopTargetMotion(parts: {BasePart})
	for _, descendant in parts do
		if descendant:IsA("BasePart") and not descendant.Anchored then
			descendant.AssemblyLinearVelocity = Vector3.zero
			descendant.AssemblyAngularVelocity = Vector3.zero
		end
	end
end

local function findRigRoot(model: Model, parts: {BasePart}, hitPosition: Vector3): BasePart
	if model.PrimaryPart and model.PrimaryPart:IsDescendantOf(model) then
		return model.PrimaryPart
	end

	local closestPart = parts[1]
	local closestDistance = math.huge
	for _, part in parts do
		local localPoint = part.CFrame:PointToObjectSpace(hitPosition)
		local halfSize = part.Size * 0.5 + Vector3.one * 0.05
		if math.abs(localPoint.X) <= halfSize.X
			and math.abs(localPoint.Y) <= halfSize.Y
			and math.abs(localPoint.Z) <= halfSize.Z
		then
			return part
		end

		local distance = (part.Position - hitPosition).Magnitude
		if distance < closestDistance then
			closestPart = part
			closestDistance = distance
		end
	end

	return closestPart
end


local function createModelRig(target: DragTarget, parts: {BasePart}, hitPosition: Vector3): ModelRig
	local model = if target:IsA("Model") then target else nil
	local root = if model then findRigRoot(model, parts, hitPosition) else target :: BasePart
	local partStates = {}
	local originalPrimaryPart = if model then model.PrimaryPart else nil

	-- A Model is only a container; its parts can otherwise fall independently.
	-- Temporarily make it one unanchored assembly while it is being dragged.
	for _, part in parts do
		table.insert(partStates, {
			part = part,
			anchored = part.Anchored,
		})
		part.Anchored = false
	end

	local container = Instance.new("Folder")
	container.Name = "DragSystemTemporaryRig"
	container.Parent = target

	for _, part in parts do
		if part ~= root then
			local weld = Instance.new("WeldConstraint")
			weld.Name = "DragSystemWeld"
			weld.Part0 = root
			weld.Part1 = part
			weld.Parent = container
		end
	end
	if model then model.PrimaryPart = root end

	return {
		model = model,
		root = root,
		container = container,
		partStates = partStates,
		originalPrimaryPart = originalPrimaryPart,
	}
end

local function destroyModelRig(rig: ModelRig?)
	if not rig then
		return
	end

	if rig.container.Parent then
		rig.container:Destroy()
	end
	pcall(function()
		if not rig.model then return end
		if rig.originalPrimaryPart and rig.originalPrimaryPart:IsDescendantOf(rig.model) then
			rig.model.PrimaryPart = rig.originalPrimaryPart
		else
			rig.model.PrimaryPart = nil
		end
	end)
	for _, state in rig.partStates do
		if state.part.Parent then
			state.part.Anchored = state.anchored
		end
	end
end

local function createPhysicsDragRig(
	target: DragTarget,
	root: BasePart,
	pivot: CFrame,
	hitPosition: Vector3,
	boxSize: Vector3,
	collisionMode: string,
	weight: number,
	parts: {BasePart}
): PhysicsDragRig
	local collisionStates = {}
	if collisionMode == config.COLLISION_MODE_NO_CLIP then
		for _, part in parts do
			table.insert(collisionStates, {
				part = part,
				canCollide = part.CanCollide,
			})
			part.CanCollide = false
		end
	end

	local container = Instance.new("Folder")
	container.Name = "DragSystemPhysicsRig"
	container.Parent = target

	local attachment = Instance.new("Attachment")
	attachment.Name = "DragSystemGrabAttachment"
	attachment.Position = root.CFrame:PointToObjectSpace(hitPosition)
	attachment.Parent = root

	local physicsSettings = dragWeight.getPhysicsSettings(weight, config)
	local assemblyMass = math.max(root.AssemblyMass, 0.001)
	local gravity = math.max(workspace.Gravity, 1)
	local objectRadius = math.max(boxSize.Magnitude * 0.5, 0.5)

	local alignPosition = Instance.new("AlignPosition")
	alignPosition.Name = "DragSystemAlignPosition"
	alignPosition.Mode = Enum.PositionAlignmentMode.OneAttachment
	alignPosition.Attachment0 = attachment
	alignPosition.Position = hitPosition
	alignPosition.ApplyAtCenterOfMass = false
	alignPosition.ReactionForceEnabled = false
	alignPosition.RigidityEnabled = false
	alignPosition.MaxForce = assemblyMass * gravity * physicsSettings.forceGravityMultiplier
	alignPosition.MaxVelocity = physicsSettings.maxVelocity
	alignPosition.Responsiveness = physicsSettings.positionResponsiveness
	alignPosition.Parent = container

	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Name = "DragSystemAlignOrientation"
	alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOrientation.Attachment0 = attachment
	alignOrientation.CFrame = root.CFrame.Rotation
	alignOrientation.ReactionTorqueEnabled = false
	alignOrientation.RigidityEnabled = false
	alignOrientation.MaxTorque = assemblyMass * gravity * objectRadius * physicsSettings.orientationTorqueMultiplier
	alignOrientation.MaxAngularVelocity = physicsSettings.maxAngularVelocity
	alignOrientation.Responsiveness = physicsSettings.orientationResponsiveness
	alignOrientation.Parent = container

	return {
		root = root,
		rootOffsetFromPivot = pivot:ToObjectSpace(root.CFrame),
		container = container,
		attachment = attachment,
		alignPosition = alignPosition,
		alignOrientation = alignOrientation,
		collisionStates = collisionStates,
	}
end

local function destroyPhysicsDragRig(rig: PhysicsDragRig?)
	if not rig then
		return
	end

	if rig.container.Parent then
		rig.container:Destroy()
	end
	if rig.attachment.Parent then
		rig.attachment:Destroy()
	end

	for _, state in rig.collisionStates do
		if state.part.Parent then
			state.part.CanCollide = state.canCollide
		end
	end

end

local function endSession(player: Player)
	local session = sessionsByPlayer[player]
	if not session then
		return
	end

	sessionsByPlayer[player] = nil
	for _, member in session.members do
		if ownerByTarget[member] == player then ownerByTarget[member] = nil end
	end

	stopTargetMotion(session.assembly.parts)
	setNetworkOwner(session.assembly.parts, nil, false)
	destroyPhysicsDragRig(session.physicsRig)
	destroyModelRig(session.modelRig)
	setNetworkOwner(session.assembly.parts, nil, true)
	session.release()
	if player.Parent == Players then dragEndedRemote:FireClient(player, session.target, session.id) end
end

local function beginDrag(player: Player, target: any, hitPosition: any, request: PendingRequest): (boolean, DragTarget?, any?)
	endSession(player)

	if not isValidTarget(target) or typeof(hitPosition) ~= "Vector3" or not isFiniteVector(hitPosition) then
		return false
	end

	local typedTarget = getPreferredTarget(target :: DragTarget)
	local root = getCharacterRoot(player)
	if not root
		or (root.Position - hitPosition).Magnitude > config.MAX_GRAB_DISTANCE
		or not isPointInsideTarget(typedTarget, hitPosition)
		or ownerByTarget[typedTarget] ~= nil
	then
		return false
	end
	local members = weldServer.GetAssemblyTargets(typedTarget)
	if not isGroupDraggable(members) then return false end
	local parts = objectTargets.getParts(members)
	local release = interactionLocks:TryAcquire(objectTargets.getLockKeys(members, parts))
	if not release then return false end
	request.release = release
	for _, member in members do
		if request.cancelled or not dragServer.CanGrab(member, player.UserId) then return false end
	end
	root = getCharacterRoot(player)
	if request.cancelled or player.Parent ~= Players or not root or not isValidTarget(typedTarget)
		or not isGroupDraggable(members)
		or (root.Position - hitPosition).Magnitude > config.MAX_GRAB_DISTANCE
		or not weldServer.IsSameAssembly(typedTarget, members) then return false end
	for _, part in parts do if not part:IsDescendantOf(workspace) then return false end end

	local modelRig = createModelRig(typedTarget, parts, hitPosition)
	request.modelRig = modelRig
	local pivot = typedTarget:GetPivot()
	local assembly = dragAssembly.capture(typedTarget, modelRig.root, parts)
	local boxSize = assembly.boxSize
	local collisionMode = getCollisionMode(typedTarget)
	local weight = 0
	for _, member in members do weight = math.min(weight + getWeight(member), 1e6) end
	local physicsRig: PhysicsDragRig? = nil
	if shouldUsePhysics(weight) then
		local physicsRoot = modelRig.root
		physicsRig = createPhysicsDragRig(
			typedTarget,
			physicsRoot,
			pivot,
			hitPosition,
			boxSize,
			collisionMode,
			weight,
			parts
		)
		request.physicsRig = physicsRig
	end
	local clientAuthoritative = false
	if physicsRig then
		setNetworkOwner(parts, nil, false)
	else
		setNetworkOwner(parts, player, false)
		clientAuthoritative = isNetworkOwnedBy(parts, player)
	end

	nextSessionId += 1
	sessionsByPlayer[player] = {
		id = nextSessionId,
		target = typedTarget,
		members = members,
		assembly = assembly,
		release = release,
		localGrabPoint = pivot:PointToObjectSpace(hitPosition),
		rotation = pivot.Rotation,
		collisionMode = collisionMode,
		rotationMode = getRotationMode(typedTarget),
		boxOffset = assembly.boxOffset,
		boxSize = boxSize,
		lastPivot = pivot,
		weight = weight,
		dragVelocity = CFrame.new(),
		lastUpdateAt = os.clock(),
		clientAuthoritative = clientAuthoritative,
		modelRig = modelRig,
		physicsRig = physicsRig,
	}
	for _, member in members do ownerByTarget[member] = player end
	stopTargetMotion(parts)
	return true, typedTarget, {
		id = nextSessionId, assembly = assembly, weight = weight,
		rotation = pivot.Rotation, localGrabPoint = pivot:PointToObjectSpace(hitPosition),
		collisionMode = collisionMode, rotationMode = getRotationMode(typedTarget),
		clientAuthoritative = clientAuthoritative,
	}
end

beginDragRemote.OnServerInvoke = function(player: Player, target: any, hitPosition: any)
	if pendingByPlayer[player] then return false end
	local request: PendingRequest = {cancelled = false}
	pendingByPlayer[player] = request
	local ok, accepted, acceptedTarget, payload = pcall(beginDrag, player, target, hitPosition, request)
	pendingByPlayer[player] = nil
	if not ok or not accepted then
		destroyPhysicsDragRig(request.physicsRig)
		destroyModelRig(request.modelRig)
		if request.release then request.release() end
		if not ok then warn("DragSystem: grab failed:", accepted) end
		return false
	end
	return accepted, acceptedTarget, payload
end

updateDragRemote.OnServerEvent:Connect(function(player: Player, target: any, desiredPivot: any, sessionId: any, rotationEdited: any)
	local session = sessionsByPlayer[player]
	if not session or target ~= session.target or sessionId ~= session.id then
		return
	end

	if not isValidTarget(session.target)
		or not isGroupDraggable(session.members)
		or typeof(desiredPivot) ~= "CFrame"
		or not isFiniteCFrame(desiredPivot)
	then
		endSession(player)
		return
	end

	local root = getCharacterRoot(player)
	local desiredRotation = session.rotation
	if session.rotationMode == config.ROTATION_MODE_CAMERA_RELATIVE or rotationEdited == true then
		desiredRotation = desiredPivot.Rotation
	end
	if rotationEdited == true then session.rotation = desiredRotation end
	local sanitizedPivot = CFrame.new(desiredPivot.Position) * desiredRotation
	local grabPosition = sanitizedPivot:PointToWorldSpace(session.localGrabPoint)
	if not root or (root.Position - grabPosition).Magnitude > config.MAX_GRAB_DISTANCE then
		endSession(player)
		return
	end

	local physicsRig = session.physicsRig
	if physicsRig then
		if not physicsRig.container:IsDescendantOf(session.target)
			or not physicsRig.attachment:IsDescendantOf(physicsRig.root)
		then
			endSession(player)
			return
		end

		local desiredRoot = sanitizedPivot * physicsRig.rootOffsetFromPivot
		physicsRig.alignPosition.Position = grabPosition
		physicsRig.alignOrientation.CFrame = desiredRoot.Rotation
		session.lastPivot = dragAssembly.getPivot(session.assembly)
		return
	end

	if session.clientAuthoritative then
		local actualPivot = dragAssembly.getPivot(session.assembly)
		local actualGrabPosition = actualPivot:PointToWorldSpace(session.localGrabPoint)
		if not isFiniteCFrame(actualPivot)
			or (root.Position - actualGrabPosition).Magnitude
				> config.MAX_GRAB_DISTANCE + config.CLIENT_OWNERSHIP_POSITION_TOLERANCE
		then
			dragAssembly.move(session.assembly, session.lastPivot)
			endSession(player)
			return
		end

		session.lastPivot = actualPivot
		return
	end

	local movementPivot = sanitizedPivot
	if session.weight > 0 then
		local now = os.clock()
		local deltaTime = math.min(math.max(now - session.lastUpdateAt, 0), 0.25)
		session.lastUpdateAt = now
		local smoothTime = math.max(session.weight * config.WEIGHT_SMOOTH_TIME_SCALE, 1 / 240)
		movementPivot, session.dragVelocity = TweenService:SmoothDamp(
			session.lastPivot,
			sanitizedPivot,
			session.dragVelocity,
			smoothTime,
			math.huge,
			deltaTime
		)
	end

	local resolvedPivot = movementPivot
	if session.collisionMode == config.COLLISION_MODE_COLLIDE then
		resolvedPivot = dragCollision.resolvePivot(
			session.assembly.parts,
			player.Character,
			session.lastPivot,
			movementPivot,
			session.boxOffset,
			session.boxSize
		)
		if resolvedPivot ~= movementPivot then
			session.dragVelocity = CFrame.new()
		end
	end

	dragAssembly.move(session.assembly, resolvedPivot)
	session.lastPivot = resolvedPivot
	stopTargetMotion(session.assembly.parts)
end)

endDragRemote.OnServerEvent:Connect(function(player: Player, target: any, sessionId: any)
	local session = sessionsByPlayer[player]
	if session and session.target == target and session.id == sessionId then
		endSession(player)
	end
end)

local function cancelPending(player: Player)
	local request = pendingByPlayer[player]
	if request then
		request.cancelled = true
		if request.release then request.release() end
	end
end

Players.PlayerRemoving:Connect(function(player)
	cancelPending(player)
	endSession(player)
end)

local function watchPlayer(player: Player)
	player.CharacterRemoving:Connect(function()
		cancelPending(player)
		endSession(player)
	end)
end

for _, player in Players:GetPlayers() do
	watchPlayer(player)
end
Players.PlayerAdded:Connect(watchPlayer)

local ownershipCheckAccumulator = 0
RunService.Heartbeat:Connect(function(deltaTime: number)
	ownershipCheckAccumulator += deltaTime
	if ownershipCheckAccumulator < config.CLIENT_OWNERSHIP_CHECK_INTERVAL then
		return
	end
	ownershipCheckAccumulator = 0

	local sessionsToEnd = {}
	for player, session in sessionsByPlayer do
		local valid = getCharacterRoot(player) ~= nil and isValidTarget(session.target)
			and isGroupDraggable(session.members)
			and weldServer.IsSameAssembly(session.target, session.members)
		for _, part in session.assembly.parts do
			if not part:IsDescendantOf(workspace) then valid = false; break end
		end
		if not valid then table.insert(sessionsToEnd, player); continue end
		if session.clientAuthoritative then
			local root = getCharacterRoot(player)
			if not root or not session.target:IsDescendantOf(workspace) then
				table.insert(sessionsToEnd, player)
				continue
			end

			local actualPivot = dragAssembly.getPivot(session.assembly)
			local actualGrabPosition = actualPivot:PointToWorldSpace(session.localGrabPoint)
			if not isFiniteCFrame(actualPivot)
				or (root.Position - actualGrabPosition).Magnitude
					> config.MAX_GRAB_DISTANCE + config.CLIENT_OWNERSHIP_POSITION_TOLERANCE
			then
				dragAssembly.move(session.assembly, session.lastPivot)
				table.insert(sessionsToEnd, player)
			else
				session.lastPivot = actualPivot
			end
		end
	end

	for _, player in sessionsToEnd do
		endSession(player)
	end
end)

CollectionService:GetInstanceRemovedSignal(config.TAG_NAME):Connect(function(instance: Instance)
	local owner = ownerByTarget[instance]
	if owner and (config.REQUIRE_ALL_MEMBERS_DRAGGABLE or sessionsByPlayer[owner].target == instance) then
		endSession(owner)
	end
end)
