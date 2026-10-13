return function(mock, modules)
	local checks = 0
	local function check(value, message) assert(value, message); checks += 1 end
	local function near(a, b) return math.abs(a - b) < 1e-6 end
	local function vectorNear(a, b) return near(a.X, b.X) and near(a.Y, b.Y) and near(a.Z, b.Z) end
	local function frameNear(a, b)
		return vectorNear(a.Position, b.Position) and vectorNear(a.XVector, b.XVector)
			and vectorNear(a.YVector, b.YVector) and vectorNear(a.ZVector, b.ZVector)
	end
	local geometry, config = modules.DragManipulation, table.clone(modules.DragConfig)
	config.MANIPULATION_ROTATION_SPEED = 90
	config.MANIPULATION_DISTANCE_STEP = 2
	config.MANIPULATION_MIN_DISTANCE, config.MANIPULATION_MAX_DISTANCE = 3, 12
	check(geometry.adjustDistance(8, 1, config) == 6, "Wheel forward brings the grab point closer")
	check(geometry.adjustDistance(8, -1, config) == 10, "Wheel backward moves the grab point away")
	check(geometry.adjustDistance(8, 100, config) == 3, "Wheel respects minimum distance")
	check(geometry.adjustDistance(8, -100, config) == 12, "Wheel respects maximum distance")
	check(geometry.adjustDistance(8, 0.25, config) == 7.5, "Fractional wheel increments are supported")
	config.MANIPULATION_MIN_DISTANCE, config.MANIPULATION_MAX_DISTANCE = 9, 3
	check(geometry.adjustDistance(8, -1, config) == 9, "Inverted distance limits form a valid interval")
	config.MANIPULATION_DISTANCE_STEP = -1
	check(geometry.adjustDistance(9, 1, config) == 9, "Negative distance step does not invert controls")

	local identity = mock.CFrame.new()
	local yaw = geometry.rotate(identity, identity, 0, 1, 1, config)
	check(vectorNear(yaw.RightVector, mock.Vector3.new(0, 0, -1)), "A rotates around world vertical at configured speed")
	check(frameNear(geometry.rotate(yaw, identity, 0, -1, 1, config), identity), "D reverses the yaw")
	local pitch = geometry.rotate(identity, identity, 1, 0, 1, config)
	check(vectorNear(pitch.ZVector, mock.Vector3.new(0, -1, 0)), "W pitches upward around camera right")
	check(frameNear(geometry.rotate(pitch, identity, -1, 0, 1, config), identity), "S reverses the pitch")
	local split = identity
	for _ = 1, 60 do split = geometry.rotate(split, identity, 0, 1, 1/60, config) end
	check(frameNear(split, yaw), "Rotation speed is independent of frame rate")
	check(frameNear(geometry.rotate(yaw, identity, 0, 0, 1, config), yaw), "No input preserves the rotation")
	check(frameNear(geometry.rotate(yaw, identity, 1, 1, 0, config), yaw), "Zero delta time cannot rotate the object")
	local screenPitch = geometry.rotate(identity, yaw, 1, 0, 1, config)
	check(vectorNear(screenPitch.RightVector, mock.Vector3.new(0, -1, 0)), "Pitch uses the actual camera horizontal axis")
	local localGrab, worldGrab = mock.Vector3.new(1, 2, 3), mock.Vector3.new(4, 5, 6)
	local pivot = geometry.desiredPivot(worldGrab, pitch * yaw, localGrab)
	check(vectorNear(pivot:PointToWorldSpace(localGrab), worldGrab), "Off-center rotation keeps the clicked point under the cursor")
	local cameraRelative = yaw:ToObjectSpace(pitch)
	check(frameNear(yaw * cameraRelative, pitch), "Manual rotation can rebase camera-relative rotation without snapping")

	local player = mock.player(301)
	local humanoid = player.Character:FindFirstChildWhichIsA("Humanoid")
	humanoid.WalkSpeed, humanoid.AutoRotate = 23, true
	local camera = mock.Instance.new("Camera")
	camera.CFrame, camera.Focus, camera.CameraType = mock.CFrame.new(0, 0, 10), identity, "CustomCamera"
	mock.workspace.CurrentCamera = camera
	local input, actions = mock.services.UserInputService, mock.services.ContextActionService
	local wheel = 0
	local controller = modules.DragInputController.new(player, function(delta) wheel += delta end)
	controller:SetDragging(true)
	check(not controller:IsActive() and humanoid.WalkSpeed == 23, "Normal dragging keeps camera and movement available")
	check(actions.bindings.DragSystemModifier.priority > 3000, "Shift interception precedes default actions")
	local function key(code, pressed)
		input.keys[code] = pressed
		actions.bindings.DragSystemModifier.callback("", if pressed then mock.Enum.UserInputState.Begin else mock.Enum.UserInputState.End,
			{KeyCode = code})
	end
	key(mock.Enum.KeyCode.LeftShift, true)
	check(controller:IsActive() and camera.CameraType == mock.Enum.CameraType.Scriptable,
		"Shift switches the camera to a temporary locked mode")
	check(humanoid.WalkSpeed == 0 and not humanoid.AutoRotate and not humanoid.Jump,
		"Shift stops character movement and automatic turning")
	check(player.CameraMinZoomDistance == 10 and player.CameraMaxZoomDistance == 10, "Camera zoom bounds lock at the existing zoom")
	camera.CFrame, camera.Focus = mock.CFrame.new(999, 0, 0), mock.CFrame.new(999, 0, 0)
	controller:Update()
	check(vectorNear(camera.CFrame.Position, mock.Vector3.new(0, 0, 10)) and frameNear(camera.Focus, identity), "Locked camera position and focus stay fixed")
	input.keys[mock.Enum.KeyCode.W], input.keys[mock.Enum.KeyCode.A] = true, true
	local p, y = controller:GetRotationInput()
	check(p == 1 and y == 1, "W and A become positive rotation inputs")
	input.keys[mock.Enum.KeyCode.S], input.keys[mock.Enum.KeyCode.D] = true, true
	p, y = controller:GetRotationInput()
	check(p == 0 and y == 0, "Opposite rotation keys cancel")
	local control = actions.bindings.DragSystemManipulation.callback
	local result = control("", mock.Enum.UserInputState.Change,
		{UserInputType = mock.Enum.UserInputType.MouseWheel, Position = mock.Vector3.new(0, 0, -2)})
	check(wheel == -2 and result == mock.Enum.ContextActionResult.Sink, "Wheel updates the object and consumes camera input")
	key(mock.Enum.KeyCode.RightShift, true); key(mock.Enum.KeyCode.LeftShift, false)
	check(controller:IsActive(), "Either Shift key can keep the mode active")
	key(mock.Enum.KeyCode.RightShift, false)
	check(not controller:IsActive() and camera.CameraType == "CustomCamera" and humanoid.WalkSpeed == 23 and humanoid.AutoRotate,
		"Releasing the last Shift restores the original camera and movement")
	check(player.CameraMinZoomDistance == 0.5 and player.CameraMaxZoomDistance == 128, "Releasing Shift restores original camera zoom limits")
	result = control("", mock.Enum.UserInputState.Change,
		{UserInputType = mock.Enum.UserInputType.MouseWheel, Position = mock.Vector3.new(0, 0, 1)})
	check(result == mock.Enum.ContextActionResult.Pass and wheel == -2, "Wheel outside Shift passes through to camera controls")
	key(mock.Enum.KeyCode.LeftShift, true)
	input.focused = {}
	controller:Update(); p, y = controller:GetRotationInput()
	check(not controller:IsActive() and p == 0 and y == 0, "Text input cannot rotate the object or retain camera locks")
	input.focused = nil
	controller:Update()
	check(controller:IsActive(), "Mode resumes if Shift is still held after text input")
	controller:SetDragging(false)
	check(not controller:IsActive() and not actions.bindings.DragSystemModifier
		and not actions.bindings.DragSystemManipulation and humanoid.WalkSpeed == 23, "Ending dragging restores state and removes temporary bindings")
	humanoid.WalkSpeed, humanoid.AutoRotate = 0, false
	controller:SetDragging(true)
	check(controller:IsActive(), "A Shift held before grab is recognized immediately")
	controller:Destroy(); controller:Destroy()
	check(humanoid.WalkSpeed == 0 and not humanoid.AutoRotate, "Cleanup preserves preexisting movement restrictions and is idempotent")
	table.clear(input.keys)

	-- Exercise actual server handlers with full rotation matrices, without simulating physics.
	local actor = mock.player(302)
	local part = mock.part("ManualRotation", 2)
	part.Anchored = true
	part:SetAttribute("weight", 1)
	mock.services.CollectionService:AddTag(part, "can-drag")
	local remotes = mock.services.ReplicatedStorage.DragRemotes
	local grabPoint = part.Position + mock.Vector3.new(0.5, 0, 0)
	local accepted, _, payload = remotes.BeginDrag.OnServerInvoke(actor, part, grabPoint)
	check(accepted and not payload.clientAuthoritative, "Manual rotation test uses physical dragging")
	local desired = geometry.desiredPivot(grabPoint, yaw, payload.localGrabPoint)
	remotes.UpdateDrag.OnServerEvent:Fire(actor, part, desired, payload.id, false)
	local rig = part.DragSystemPhysicsRig
	check(frameNear(rig.DragSystemAlignOrientation.CFrame, identity), "World mode retains rotation without an explicit manual edit")
	remotes.UpdateDrag.OnServerEvent:Fire(actor, part, desired, payload.id, true)
	check(frameNear(rig.DragSystemAlignOrientation.CFrame, yaw)
		and vectorNear(rig.DragSystemAlignPosition.Position, grabPoint), "Manual edit rotates physical goal around the fixed grab point")
	remotes.UpdateDrag.OnServerEvent:Fire(actor, part, desired, payload.id, false)
	check(frameNear(rig.DragSystemAlignOrientation.CFrame, yaw), "Server retains manual World rotation after the modifier is released")
	remotes.UpdateDrag.OnServerEvent:Fire(actor, part, mock.CFrame.new(100, 0, 0), payload.id, true)
	check(not part.Anchored and rig.DragSystemAlignPosition.Position.Magnitude <= modules.DragConfig.MAX_GRAB_DISTANCE + 1e-6,
		"Out-of-range manual goals are bounded without cancelling the session")
	remotes.UpdateDrag.OnServerEvent:Fire(actor, part, mock.CFrame.new(0/0, 0, 0), payload.id, true)
	check(part.Anchored and not part.DragSystemPhysicsRig, "Non-finite goals still stop invalid dragging and restore properties")
	print("Drag controls: " .. checks .. " checks passed (mocked camera/input/engine)")
end
