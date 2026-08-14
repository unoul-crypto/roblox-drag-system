local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local config = require(ReplicatedStorage.Shared.DragConfig)
local dragCollision = require(ReplicatedStorage.Shared.DragCollision)
local remotes = ReplicatedStorage:WaitForChild("DragRemotes")
local beginDragRemote = remotes:WaitForChild("BeginDrag") :: RemoteFunction
local updateDragRemote = remotes:WaitForChild("UpdateDrag") :: RemoteEvent
local endDragRemote = remotes:WaitForChild("EndDrag") :: RemoteEvent

type DragTarget = BasePart | Model

type DragState = {
	target: DragTarget,
	localGrabPoint: Vector3,
	grabDistance: number,
	rotation: CFrame,
	cameraRelativeRotation: CFrame,
	collisionMode: string,
	rotationMode: string,
	boxOffset: CFrame,
	boxSize: Vector3,
	marker: BasePart,
	parts: {BasePart},
	lastUpdate: number,
}

local hoveredTarget: DragTarget? = nil
local dragState: DragState? = nil

local hoverHighlight = Instance.new("Highlight")
hoverHighlight.Name = "DragHoverHighlight"
hoverHighlight.DepthMode = Enum.HighlightDepthMode.Occluded
hoverHighlight.FillColor = config.MARKER_COLOR
hoverHighlight.FillTransparency = 0.85
hoverHighlight.OutlineColor = config.MARKER_COLOR
hoverHighlight.OutlineTransparency = 0.15
hoverHighlight.Enabled = false
hoverHighlight.Parent = workspace

local function getCharacterRoot(): BasePart?
	local character = player.Character
	if not character then
		return nil
	end

	return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function isSupportedTarget(instance: Instance): boolean
	if instance:IsA("BasePart") then
		return instance:IsDescendantOf(workspace)
	end

	if instance:IsA("Model") then
		return instance:IsDescendantOf(workspace) and instance:FindFirstChildWhichIsA("BasePart", true) ~= nil
	end

	return false
end

local function findTaggedTarget(hit: Instance?): DragTarget?
	local current = hit

	while current and current ~= workspace do
		if CollectionService:HasTag(current, config.TAG_NAME) and isSupportedTarget(current) then
			return current :: DragTarget
		end

		current = current.Parent
	end

	return nil
end

local function getMouseRay(): Ray?
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end

	local mousePosition = UserInputService:GetMouseLocation()
	return camera:ViewportPointToRay(mousePosition.X, mousePosition.Y)
end

local function raycastFromMouse(excludedTarget: DragTarget?): RaycastResult?
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end

	local excludedInstances = {}
	if player.Character then
		table.insert(excludedInstances, player.Character)
	end
	if excludedTarget then
		table.insert(excludedInstances, excludedTarget)
	end

	local parameters = RaycastParams.new()
	parameters.FilterType = Enum.RaycastFilterType.Exclude
	parameters.FilterDescendantsInstances = excludedInstances
	parameters.IgnoreWater = false

	local ray = getMouseRay()
	if not ray then
		return nil
	end

	return workspace:Raycast(ray.Origin, ray.Direction * config.MAX_RAY_DISTANCE, parameters)
end

local function isInReach(worldPosition: Vector3): boolean
	local root = getCharacterRoot()
	return root ~= nil and (root.Position - worldPosition).Magnitude <= config.MAX_GRAB_DISTANCE
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

local function setHoveredTarget(target: DragTarget?)
	if hoveredTarget == target then
		return
	end

	hoveredTarget = target
	hoverHighlight.Adornee = target
	hoverHighlight.Enabled = target ~= nil
end

local function updateHover()
	if dragState then
		setHoveredTarget(nil)
		return
	end

	local result = raycastFromMouse(nil)
	local target = result and findTaggedTarget(result.Instance) or nil

	if target and result and isInReach(result.Position) then
		setHoveredTarget(target)
	else
		setHoveredTarget(nil)
	end
end

local function createGrabMarker(): BasePart
	local marker = Instance.new("Part")
	marker.Name = "DragGrabPoint"
	marker.Shape = Enum.PartType.Ball
	marker.Size = Vector3.one * config.MARKER_SIZE
	marker.Color = config.MARKER_COLOR
	marker.Material = Enum.Material.Neon
	marker.Anchored = true
	marker.CanCollide = false
	marker.CanQuery = false
	marker.CanTouch = false
	marker.CastShadow = false
	marker.Parent = workspace
	return marker
end

local function getTargetParts(target: DragTarget): {BasePart}
	if target:IsA("BasePart") then
		return {target}
	end

	local parts = {}
	for _, descendant in target:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

local function stopTargetMotion(parts: {BasePart})
	for _, part in parts do
		if not part.Anchored then
			part.AssemblyLinearVelocity = Vector3.zero
			part.AssemblyAngularVelocity = Vector3.zero
		end
	end
end

local function finishDrag(notifyServer: boolean)
	local state = dragState
	if not state then
		return
	end

	dragState = nil
	state.marker:Destroy()
	stopTargetMotion(state.parts)

	if notifyServer then
		endDragRemote:FireServer(state.target)
	end
end

local function startDrag()
	if dragState then
		return
	end

	local result = raycastFromMouse(nil)
	if not result then
		return
	end

	local target = findTaggedTarget(result.Instance)
	if not target or not isInReach(result.Position) then
		return
	end

	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	local pivot = target:GetPivot()
	local boxCFrame, boxSize = dragCollision.getBoundingBox(target)
	local grabDistance = (result.Position - camera.CFrame.Position).Magnitude
	local requestSucceeded, accepted = pcall(function()
		return beginDragRemote:InvokeServer(target, result.Position)
	end)
	if not requestSucceeded then
		warn("DragSystem: server did not answer the drag request")
		return
	end
	if accepted ~= true or not target:IsDescendantOf(workspace) then
		return
	end
	if not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
		endDragRemote:FireServer(target)
		return
	end

	local marker = createGrabMarker()
	marker.Position = result.Position
	dragState = {
		target = target,
		localGrabPoint = pivot:PointToObjectSpace(result.Position),
		grabDistance = grabDistance,
		rotation = pivot.Rotation,
		cameraRelativeRotation = camera.CFrame.Rotation:ToObjectSpace(pivot.Rotation),
		collisionMode = getCollisionMode(target),
		rotationMode = getRotationMode(target),
		boxOffset = pivot:ToObjectSpace(boxCFrame),
		boxSize = boxSize,
		marker = marker,
		parts = getTargetParts(target),
		lastUpdate = 0,
	}
	setHoveredTarget(nil)
end

local function updateDrag()
	local state = dragState
	if not state then
		return
	end

	if not state.target:IsDescendantOf(workspace)
		or not CollectionService:HasTag(state.target, config.TAG_NAME)
		or not getCharacterRoot()
	then
		finishDrag(true)
		return
	end

	local root = getCharacterRoot()
	if not root then
		finishDrag(true)
		return
	end

	local ray = getMouseRay()
	if not ray then
		return
	end

	local targetGrabPosition = ray.Origin + ray.Direction.Unit * state.grabDistance
	local offsetFromPlayer = targetGrabPosition - root.Position
	if offsetFromPlayer.Magnitude > config.MAX_GRAB_DISTANCE then
		targetGrabPosition = root.Position + offsetFromPlayer.Unit * (config.MAX_GRAB_DISTANCE - 0.1)
	end

	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	local desiredRotation = state.rotation
	if state.rotationMode == config.ROTATION_MODE_CAMERA_RELATIVE then
		desiredRotation = camera.CFrame.Rotation * state.cameraRelativeRotation
	end

	local desiredPivot = CFrame.new(targetGrabPosition) * desiredRotation * CFrame.new(-state.localGrabPoint)
	local resolvedPivot = desiredPivot
	if state.collisionMode == config.COLLISION_MODE_COLLIDE then
		resolvedPivot = dragCollision.resolvePivot(
			state.target,
			player.Character,
			state.target:GetPivot(),
			desiredPivot,
			state.boxOffset,
			state.boxSize
		)
	end

	state.target:PivotTo(resolvedPivot)
	stopTargetMotion(state.parts)
	state.marker.Position = resolvedPivot:PointToWorldSpace(state.localGrabPoint)

	local now = os.clock()
	if now - state.lastUpdate >= config.UPDATE_RATE then
		state.lastUpdate = now
		updateDragRemote:FireServer(state.target, desiredPivot)
	end
end

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end

	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		startDrag()
	end
end)

UserInputService.InputEnded:Connect(function(input: InputObject)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		finishDrag(true)
	end
end)

player.CharacterRemoving:Connect(function()
	finishDrag(true)
end)

RunService:BindToRenderStep("DragSystem", Enum.RenderPriority.Camera.Value + 1, function()
	updateHover()
	updateDrag()
end)
