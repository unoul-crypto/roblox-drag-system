local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local config = require(ReplicatedStorage.Shared.DragConfig)
local dragCollision = require(ReplicatedStorage.Shared.DragCollision)
local dragWeight = require(ReplicatedStorage.Shared.DragWeight)
local dragAssembly = require(ReplicatedStorage.Shared.DragAssembly)
local dragManipulation = require(ReplicatedStorage.Shared.DragManipulation)
local physicsTargetMotion = require(ReplicatedStorage.Shared.PhysicsTargetMotion)
local physicsDragStability = require(ReplicatedStorage.Shared.PhysicsDragStability)
local objectTargets = require(ReplicatedStorage.Shared.ObjectTargets)
local objectMechanisms = require(ReplicatedStorage.Shared.ObjectMechanisms)
local dragServer = require(script.DragServer)
local weldServer = require(script.WeldServer)
local interactionLocks = require(script.InteractionLocks)
local interactionCharacter = require(ReplicatedStorage.Shared.InteractionCharacter)
local interactionVisibility = require(ReplicatedStorage.Shared.InteractionVisibility)
local RequestLimiter = require(ReplicatedStorage.Shared.RequestLimiter)
local beginLimiter = RequestLimiter.new()
local updateLimiter = RequestLimiter.new()
local serverOwnership = require(script.ServerOwnership)
local freezeServer = require(script.FreezeServer)
serverOwnership.Start()

type DragTarget = BasePart | Model

type PartState = {
	part: BasePart,
	anchored: boolean,
	canCollide: boolean,
}

type ModelRig = {
	model: Model?,
	root: BasePart,
	container: Folder,
	partStates: {PartState},
	originalPrimaryPart: BasePart?,
}

type PhysicsDragRig = {
	root: BasePart,
	rootOffsetFromPivot: CFrame,
	container: Folder,
	attachment: Attachment,
	alignPosition: AlignPosition,
	alignOrientation: AlignOrientation,
	requestedGrabPosition: Vector3,
	targetMotion: physicsTargetMotion.State,
	targetSettings: physicsTargetMotion.Settings,
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
	weight: number,
	dragVelocity: CFrame,
	kinematicGoal: CFrame,
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
	return interactionCharacter.getRoot(player)
end

local isFiniteVector = objectTargets.isFiniteVector
local isFiniteCFrame = objectTargets.isFiniteCFrame

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
	for _, member in members do
		if config.REQUIRE_ALL_MEMBERS_DRAGGABLE and not isValidTarget(member) then return false end
		if config.BLOCK_OCCUPIED_SEATS and objectMechanisms.hasOccupant(member) then return false end
	end
	return true
end

local function getPreferredTarget(target: DragTarget): DragTarget
	return objectTargets.findTagged(target, config.TAG_NAME) or target
end

local function isPointInsideTarget(target: DragTarget, worldPoint: Vector3): boolean
	return objectTargets.containsPoint(target, worldPoint)
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


local function createModelRig(target: DragTarget, parts: {BasePart}, hitPosition: Vector3, collisionMode: string): ModelRig
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
			canCollide = part.CanCollide,
		})
		part.Anchored = false
		if collisionMode == config.COLLISION_MODE_NO_CLIP then part.CanCollide = false end
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
			state.part.CanCollide = state.canCollide
		end
	end
end

local function createPhysicsDragRig(
	target: DragTarget,
	root: BasePart,
	pivot: CFrame,
	hitPosition: Vector3,
	boxSize: Vector3,
	weight: number
): PhysicsDragRig
	local container = Instance.new("Folder")
	container.Name = "DragSystemPhysicsRig"
	container.Parent = target

	local attachment = Instance.new("Attachment")
	attachment.Name = "DragSystemGrabAttachment"
	attachment.Position = root.CFrame:PointToObjectSpace(hitPosition)
	attachment.Parent = root

	local physicsSettings = physicsDragStability.getSettings(dragWeight.getPhysicsSettings(weight, config),boxSize,config)
	local assemblyMass = physicsDragStability.mass(root.AssemblyMass)
	local gravity = math.max(workspace.Gravity, 1)
	local objectRadius = math.max(boxSize.Magnitude * 0.5, 0.5)

	local alignPosition = Instance.new("AlignPosition")
	alignPosition.Name = "DragSystemAlignPosition"
	alignPosition.Mode = Enum.PositionAlignmentMode.OneAttachment
	alignPosition.Attachment0 = attachment
	alignPosition.Position = hitPosition
	-- Keep both the positional reference and applied force at the clicked point.
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
		requestedGrabPosition = hitPosition,
		targetMotion = physicsTargetMotion.new(hitPosition),
		targetSettings = physicsTargetMotion.getSettings(physicsSettings.maxVelocity, config),
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

end

local function endSession(player: Player, freezeOnRelease: boolean?)
	local session = sessionsByPlayer[player]
	if not session then
		return
	end

	sessionsByPlayer[player] = nil
	for _, member in session.members do
		if ownerByTarget[member] == player then ownerByTarget[member] = nil end
	end

	stopTargetMotion(session.assembly.parts)
	serverOwnership.Claim(session.assembly.parts)
	destroyPhysicsDragRig(session.physicsRig)
	destroyModelRig(session.modelRig)
	serverOwnership.Claim(session.assembly.parts)
	session.release()
	if player.Parent == Players then dragEndedRemote:FireClient(player, session.target, session.id) end
	if freezeOnRelease then
		-- Release old records before starting the new freeze, including when that freeze is denied.
		freezeServer.UnfreezeAll(player.UserId, "Released")
		local character = player.Character
		freezeServer.Freeze(session.target, player.UserId, function()
			return player.Character == character and weldServer.IsSameAssembly(session.target, session.members)
		end)
	end
end

local function beginDrag(player: Player, target: any, hitPosition: any, request: PendingRequest): (boolean, DragTarget?, any?)
	endSession(player)

	if not isValidTarget(target) or typeof(hitPosition) ~= "Vector3" or not isFiniteVector(hitPosition) then
		return false
	end

	local typedTarget = getPreferredTarget(target :: DragTarget)
	local character = player.Character
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
	if not interactionVisibility.canSee(player, hitPosition, members) then return false end
	local parts = objectTargets.getParts(members)
	local release = interactionLocks:TryAcquire(objectTargets.getLockKeys(members, parts))
	if not release then return false end
	request.release = release
	for _, member in members do
		if request.cancelled or not dragServer.CanGrab(member, player.UserId) then return false end
	end
	root = getCharacterRoot(player)
	if request.cancelled or player.Parent ~= Players or player.Character ~= character or not root or not isValidTarget(typedTarget)
		or not isGroupDraggable(members)
		or (root.Position - hitPosition).Magnitude > config.MAX_GRAB_DISTANCE
		or not weldServer.IsSameAssembly(typedTarget, members) then return false end
	if not isPointInsideTarget(typedTarget, hitPosition)
		or not interactionVisibility.canSee(player, hitPosition, members) then return false end
	for _, part in parts do
		if not part:IsDescendantOf(workspace) or not isFiniteCFrame(part.CFrame) then return false end
	end
	freezeServer.UnfreezeMembers(members, "Grabbed")

	local collisionMode = getCollisionMode(typedTarget)
	local modelRig = createModelRig(typedTarget, parts, hitPosition, collisionMode)
	request.modelRig = modelRig
	local pivot = typedTarget:GetPivot()
	local assembly = dragAssembly.capture(typedTarget, modelRig.root, parts)
	local boxSize = assembly.boxSize
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
			weight
		)
		request.physicsRig = physicsRig
	end
	if not serverOwnership.Claim(parts) then return false end

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
		weight = weight,
		dragVelocity = CFrame.new(),
		kinematicGoal = pivot,
		modelRig = modelRig,
		physicsRig = physicsRig,
	}
	for _, member in members do ownerByTarget[member] = player end
	stopTargetMotion(parts)
	dragServer.NotifyGrabbed(typedTarget, player.UserId)
	return true, typedTarget, {
		id = nextSessionId, assembly = assembly, weight = weight,
		rotation = pivot.Rotation, localGrabPoint = pivot:PointToObjectSpace(hitPosition),
		collisionMode = collisionMode, rotationMode = getRotationMode(typedTarget),
		clientAuthoritative = false, -- Compatibility for existing clients; simulation always runs on the server.
	}
end

beginDragRemote.OnServerInvoke = function(player: Player, target: any, hitPosition: any)
	if not beginLimiter:TryTake(player, config.BEGIN_REQUEST_RATE, config.BEGIN_REQUEST_BURST) then return false end
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

local function moveKinematic(player: Player, session: DragSession, root: BasePart, deltaTime: number)
	local goal = session.kinematicGoal
	local grabPoint = dragManipulation.clampGrabPoint(goal:PointToWorldSpace(session.localGrabPoint),
		root.Position, config.MAX_GRAB_DISTANCE)
	local sanitizedPivot = dragManipulation.desiredPivot(grabPoint, goal.Rotation, session.localGrabPoint)
	local currentPivot = dragAssembly.getPivot(session.assembly)
	local movementPivot = sanitizedPivot
	if session.weight > 0 then
		local smoothTime = math.max(session.weight * config.WEIGHT_SMOOTH_TIME_SCALE, 1 / 240)
		movementPivot, session.dragVelocity = TweenService:SmoothDamp(
			currentPivot,
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
			currentPivot,
			movementPivot,
			session.boxOffset,
			session.boxSize
		)
		if resolvedPivot ~= movementPivot then
			session.dragVelocity = CFrame.new()
		end
	end

	dragAssembly.move(session.assembly, resolvedPivot)
	stopTargetMotion(session.assembly.parts)
end

updateDragRemote.OnServerEvent:Connect(function(player: Player, target: any, desiredPivot: any, sessionId: any, rotationEdited: any)
	if not updateLimiter:TryTake(player, config.UPDATE_REQUEST_RATE, config.UPDATE_REQUEST_BURST) then return end
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
	if not root then
		endSession(player)
		return
	end
	-- Client and server may see different player positions while walking.
	-- Bound the requested grab point instead of cancelling an otherwise valid session.
	local requestedPivot = CFrame.new(desiredPivot.Position) * desiredRotation
	local grabPosition = dragManipulation.clampGrabPoint(
		requestedPivot:PointToWorldSpace(session.localGrabPoint), root.Position, config.MAX_GRAB_DISTANCE
	)
	local sanitizedPivot = dragManipulation.desiredPivot(grabPosition, desiredRotation, session.localGrabPoint)
	if not interactionVisibility.canSee(player, grabPosition, session.members) then return end
	if rotationEdited == true then session.rotation = desiredRotation end

	local physicsRig = session.physicsRig
	if physicsRig then
		if not physicsRig.container:IsDescendantOf(session.target)
			or not physicsRig.attachment:IsDescendantOf(physicsRig.root)
		then
			endSession(player)
			return
		end

		local desiredRoot = sanitizedPivot * physicsRig.rootOffsetFromPivot
		physicsRig.requestedGrabPosition = grabPosition
		if not config.PHYSICS_TARGET_SMOOTHING_ENABLED then
			physicsRig.alignPosition.Position = grabPosition
			physicsTargetMotion.reset(physicsRig.targetMotion, grabPosition)
		end
		physicsRig.alignOrientation.CFrame = desiredRoot.Rotation
		return
	end

	session.kinematicGoal = sanitizedPivot
	if session.weight == 0 then moveKinematic(player, session, root, 0) end
end)

endDragRemote.OnServerEvent:Connect(function(player: Player, target: any, sessionId: any)
	-- Releasing a matching session is cheap and must always work, even after a burst.
	local session = sessionsByPlayer[player]
	if session and session.target == target and session.id == sessionId then
		endSession(player, true)
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
	beginLimiter:Remove(player)
	updateLimiter:Remove(player)
end)

local function watchPlayer(player: Player)
	local deathConnection: RBXScriptConnection? = nil
	local addedConnection: RBXScriptConnection? = nil
	local function clearCharacter()
		if deathConnection then deathConnection:Disconnect(); deathConnection = nil end
		if addedConnection then addedConnection:Disconnect(); addedConnection = nil end
	end
	local function watchCharacter(character: Model)
		clearCharacter()
		local function bindHumanoid(humanoid: Instance)
			if not humanoid:IsA("Humanoid") or deathConnection then return end
			deathConnection = humanoid.Died:Connect(function()
				if player.Character ~= character then return end
				cancelPending(player)
				endSession(player)
			end)
		end
		addedConnection = character.ChildAdded:Connect(bindHumanoid)
		local humanoid = character:FindFirstChildWhichIsA("Humanoid")
		if humanoid then bindHumanoid(humanoid) end
	end
	player.CharacterAdded:Connect(watchCharacter)
	if player.Character then watchCharacter(player.Character) end
	player.CharacterRemoving:Connect(function()
		clearCharacter()
		cancelPending(player)
		endSession(player)
	end)
	player.AncestryChanged:Connect(function()
		if player.Parent ~= Players then clearCharacter() end
	end)
end

for _, player in Players:GetPlayers() do
	watchPlayer(player)
end
Players.PlayerAdded:Connect(watchPlayer)

RunService.PreSimulation:Connect(function(deltaTime: number)
	local sessionsToEnd = {}
	for player, session in sessionsByPlayer do
		local rig = session.physicsRig
		local root = getCharacterRoot(player)
		local actualPivot = dragAssembly.getPivot(session.assembly)
		if not root or not isFiniteCFrame(actualPivot) or not session.assembly.root:IsDescendantOf(workspace)
			or not serverOwnership.Claim(session.assembly.parts) then
			table.insert(sessionsToEnd, player)
			continue
		end
		if not rig then
			moveKinematic(player, session, root, math.clamp(deltaTime, 0, 0.1))
			continue
		end
		if not rig.container:IsDescendantOf(session.target)
			or not rig.attachment:IsDescendantOf(rig.root)
			or not rig.alignPosition:IsDescendantOf(rig.container)
			or not rig.alignOrientation:IsDescendantOf(rig.container) then
			table.insert(sessionsToEnd, player)
			continue
		end
		if not config.PHYSICS_TARGET_SMOOTHING_ENABLED then continue end
		local goal = dragManipulation.clampGrabPoint(rig.requestedGrabPosition, root.Position, config.MAX_GRAB_DISTANCE)
		local position = physicsTargetMotion.step(rig.targetMotion, goal, deltaTime, rig.targetSettings)
		if config.PHYSICS_TARGET_MAX_LEAD > 0 then
			position = dragManipulation.clampGrabPoint(position,
				actualPivot:PointToWorldSpace(session.localGrabPoint), config.PHYSICS_TARGET_MAX_LEAD)
		end
		position = dragManipulation.clampGrabPoint(position, root.Position, config.MAX_GRAB_DISTANCE)
		if (position - rig.targetMotion.position).Magnitude > 1e-5 then
			-- Don't store outward velocity while a reach/lead boundary holds the target.
			physicsTargetMotion.reset(rig.targetMotion, position)
		end
		rig.alignPosition.Position = position
	end
	for _, player in sessionsToEnd do endSession(player) end
end)

local ownershipCheckAccumulator = 0
RunService.Heartbeat:Connect(function(deltaTime: number)
	ownershipCheckAccumulator += deltaTime
	if ownershipCheckAccumulator < config.SERVER_VALIDATION_INTERVAL then
		return
	end
	ownershipCheckAccumulator = 0

	local sessionsToEnd = {}
	for player, session in sessionsByPlayer do
		local valid = getCharacterRoot(player) ~= nil and isValidTarget(session.target)
			and isGroupDraggable(session.members)
			and weldServer.IsSameAssembly(session.target, session.members)
			and interactionVisibility.canSee(player,
				dragAssembly.getPivot(session.assembly):PointToWorldSpace(session.localGrabPoint), session.members)
		for _, part in session.assembly.parts do
			if not part:IsDescendantOf(workspace) then valid = false; break end
		end
		if not valid then table.insert(sessionsToEnd, player); continue end

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
