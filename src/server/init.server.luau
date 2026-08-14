local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local config = require(ReplicatedStorage.Shared.DragConfig)
local dragCollision = require(ReplicatedStorage.Shared.DragCollision)

type DragTarget = BasePart | Model

type DragSession = {
	target: DragTarget,
	localGrabPoint: Vector3,
	rotation: CFrame,
	collisionMode: string,
	rotationMode: string,
	boxOffset: CFrame,
	boxSize: Vector3,
	lastPivot: CFrame,
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

local sessionsByPlayer: {[Player]: DragSession} = {}
local ownerByTarget: {[Instance]: Player} = {}

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

local function isPointInsideTarget(target: DragTarget, worldPoint: Vector3): boolean
	local boxCFrame: CFrame
	local boxSize: Vector3

	if target:IsA("BasePart") then
		boxCFrame = target.CFrame
		boxSize = target.Size
	else
		boxCFrame, boxSize = target:GetBoundingBox()
	end

	local point = boxCFrame:PointToObjectSpace(worldPoint)
	local halfSize = boxSize * 0.5 + Vector3.one
	return math.abs(point.X) <= halfSize.X
		and math.abs(point.Y) <= halfSize.Y
		and math.abs(point.Z) <= halfSize.Z
end

local function setNetworkOwner(target: DragTarget, owner: Player?, automatic: boolean?)
	local parts = if target:IsA("BasePart") then {target} else target:GetDescendants()
	local handledAssemblies: {[BasePart]: boolean} = {}

	for _, descendant in parts do
		if descendant:IsA("BasePart") and not descendant.Anchored then
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

local function stopTargetMotion(target: DragTarget)
	local parts = if target:IsA("BasePart") then {target} else target:GetDescendants()
	for _, descendant in parts do
		if descendant:IsA("BasePart") and not descendant.Anchored then
			descendant.AssemblyLinearVelocity = Vector3.zero
			descendant.AssemblyAngularVelocity = Vector3.zero
		end
	end
end

local function endSession(player: Player)
	local session = sessionsByPlayer[player]
	if not session then
		return
	end

	sessionsByPlayer[player] = nil
	if ownerByTarget[session.target] == player then
		ownerByTarget[session.target] = nil
	end

	if session.target:IsDescendantOf(workspace) then
		stopTargetMotion(session.target)
		setNetworkOwner(session.target, nil, true)
	end
end

beginDragRemote.OnServerInvoke = function(player: Player, target: any, hitPosition: any): boolean
	endSession(player)

	if not isValidTarget(target) or typeof(hitPosition) ~= "Vector3" or not isFiniteVector(hitPosition) then
		return false
	end

	local typedTarget = target :: DragTarget
	local root = getCharacterRoot(player)
	if not root
		or (root.Position - hitPosition).Magnitude > config.MAX_GRAB_DISTANCE
		or not isPointInsideTarget(typedTarget, hitPosition)
		or ownerByTarget[typedTarget] ~= nil
	then
		return false
	end

	local pivot = typedTarget:GetPivot()
	local boxCFrame, boxSize = dragCollision.getBoundingBox(typedTarget)
	local collisionMode = getCollisionMode(typedTarget)
	sessionsByPlayer[player] = {
		target = typedTarget,
		localGrabPoint = pivot:PointToObjectSpace(hitPosition),
		rotation = pivot.Rotation,
		collisionMode = collisionMode,
		rotationMode = getRotationMode(typedTarget),
		boxOffset = pivot:ToObjectSpace(boxCFrame),
		boxSize = boxSize,
		lastPivot = pivot,
	}
	ownerByTarget[typedTarget] = player
	if collisionMode == config.COLLISION_MODE_COLLIDE then
		setNetworkOwner(typedTarget, nil, false)
	else
		setNetworkOwner(typedTarget, player, false)
	end
	stopTargetMotion(typedTarget)
	return true
end

updateDragRemote.OnServerEvent:Connect(function(player: Player, target: any, desiredPivot: any)
	local session = sessionsByPlayer[player]
	if not session or target ~= session.target then
		return
	end

	if not isValidTarget(session.target)
		or typeof(desiredPivot) ~= "CFrame"
		or not isFiniteCFrame(desiredPivot)
	then
		endSession(player)
		return
	end

	local root = getCharacterRoot(player)
	local desiredRotation = session.rotation
	if session.rotationMode == config.ROTATION_MODE_CAMERA_RELATIVE then
		desiredRotation = desiredPivot.Rotation
	end
	local sanitizedPivot = CFrame.new(desiredPivot.Position) * desiredRotation
	local grabPosition = sanitizedPivot:PointToWorldSpace(session.localGrabPoint)
	if not root or (root.Position - grabPosition).Magnitude > config.MAX_GRAB_DISTANCE then
		endSession(player)
		return
	end

	local resolvedPivot = sanitizedPivot
	if session.collisionMode == config.COLLISION_MODE_COLLIDE then
		resolvedPivot = dragCollision.resolvePivot(
			session.target,
			player.Character,
			session.lastPivot,
			sanitizedPivot,
			session.boxOffset,
			session.boxSize
		)
	end

	session.target:PivotTo(resolvedPivot)
	session.lastPivot = resolvedPivot
	stopTargetMotion(session.target)
end)

endDragRemote.OnServerEvent:Connect(function(player: Player, target: any)
	local session = sessionsByPlayer[player]
	if session and session.target == target then
		endSession(player)
	end
end)

Players.PlayerRemoving:Connect(endSession)

local function watchPlayer(player: Player)
	player.CharacterRemoving:Connect(function()
		endSession(player)
	end)
end

for _, player in Players:GetPlayers() do
	watchPlayer(player)
end
Players.PlayerAdded:Connect(watchPlayer)

CollectionService:GetInstanceRemovedSignal(config.TAG_NAME):Connect(function(instance: Instance)
	local owner = ownerByTarget[instance]
	if owner then
		endSession(owner)
	end
end)
