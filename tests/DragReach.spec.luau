return function(mock, modules)
	local checks = 0
	local function check(value, message) assert(value, message); checks += 1 end
	local config = modules.DragConfig
	local geometry = modules.DragManipulation
	local origin = mock.Vector3.new(5, 2, -3)
	check(geometry.clampGrabPoint(origin, origin, 0) == origin, "Coincident grab points avoid division by zero")
	local nearPoint = origin + mock.Vector3.new(1, 2, 3)
	check(geometry.clampGrabPoint(nearPoint, origin, 24) == nearPoint, "Targets within reach retain their original position")
	local limited = geometry.clampGrabPoint(origin + mock.Vector3.new(30, 40, 0), origin, 10)
	check((limited - (origin + mock.Vector3.new(6, 8, 0))).Magnitude < 1e-6,
		"Clamping preserves the target direction relative to the player")
	local collection = mock.services.CollectionService
	local remotes = mock.services.ReplicatedStorage.DragRemotes
	local actor = mock.player(401)
	local root = actor.Character.HumanoidRootPart
	local a = mock.part("ReachA", config.MAX_GRAB_DISTANCE - 0.5)
	local b = mock.part("ReachB", config.MAX_GRAB_DISTANCE - 3)
	for _, part in {a, b} do
		part.Anchored = true
		collection:AddTag(part, "can-drag"); collection:AddTag(part, "can-weld")
	end
	a:SetAttribute("weight", 1)
	check(modules.WeldServer.Weld(a, b), "Regression uses a welded physical group")
	local grab = a.Position + mock.Vector3.new(0, 0.25, 0)
	local accepted, _, payload = remotes.BeginDrag.OnServerInvoke(actor, a, grab)
	check(accepted, "A group near the reach limit can be grabbed")
	local rotation = mock.CFrame.fromAxisAngle(mock.Vector3.yAxis, math.pi / 3)
	-- Client root has moved 0.8 studs forward while the server still sees the old root.
	local requestedGrab = mock.Vector3.new(config.MAX_GRAB_DISTANCE + 0.7, 0, 0)
	local desired = modules.DragManipulation.desiredPivot(requestedGrab, rotation, payload.localGrabPoint)
	remotes.UpdateDrag.OnServerEvent:Fire(actor, a, desired, payload.id, true)
	check(not a.Anchored and a.DragSystemPhysicsRig ~= nil,
		"Forward movement with delayed root replication must not cancel a distant grab")
	local rig = a.DragSystemPhysicsRig
	check((rig.DragSystemAlignPosition.Position - root.Position).Magnitude <= config.MAX_GRAB_DISTANCE + 1e-6,
		"Server still limits the physical target to allowed reach")
	for step = 1, 10 do
		root.CFrame = mock.CFrame.new(step, 0, 0)
		requestedGrab = root.Position + mock.Vector3.new(config.MAX_GRAB_DISTANCE + 0.7, 0, 0)
		desired = modules.DragManipulation.desiredPivot(requestedGrab, rotation, payload.localGrabPoint)
		remotes.UpdateDrag.OnServerEvent:Fire(actor, a, desired, payload.id, true)
		check(not a.Anchored and (rig.DragSystemAlignPosition.Position - root.Position).Magnitude
			<= config.MAX_GRAB_DISTANCE + 1e-6, "Walking forward keeps the group grabbed with a bounded target")
	end
	remotes.EndDrag.OnServerEvent:Fire(actor, a, payload.id)
	check(a.Anchored and b.Anchored and not modules.InteractionLocks:IsLocked(a), "Dropping still restores the whole welded group")

	local kinematicActor = mock.player(402)
	local kinematicRoot = kinematicActor.Character.HumanoidRootPart
	local part = mock.part("KinematicReach", config.MAX_GRAB_DISTANCE - 0.5)
	part.Anchored = true
	collection:AddTag(part, "can-drag")
	accepted, _, payload = remotes.BeginDrag.OnServerInvoke(kinematicActor, part, part.Position)
	check(accepted and not payload.clientAuthoritative and part:GetNetworkOwner() == nil,
		"Zero-weight regression uses server-owned dragging")
	for step = 1, 5 do
		kinematicRoot.CFrame = mock.CFrame.new(step, 0, 0)
		local requested = mock.CFrame.new(step + config.MAX_GRAB_DISTANCE + 0.7, 0, 0)
		remotes.UpdateDrag.OnServerEvent:Fire(kinematicActor, part, requested, payload.id, false)
		mock.services.RunService.PreSimulation:Fire(1/60)
		mock.services.RunService.Heartbeat:Fire(0.25)
		check(not part.Anchored and modules.InteractionLocks:IsLocked(part)
			and (part.Position - kinematicRoot.Position).Magnitude <= config.MAX_GRAB_DISTANCE + 1e-6,
			"Server-owned instantaneous movement stays bounded while walking forward")
	end
	kinematicRoot.CFrame = mock.CFrame.new(math.huge, 0, 0)
	mock.services.RunService.Heartbeat:Fire(0.25)
	check(part.Anchored and not modules.InteractionLocks:IsLocked(part), "Invalid character position cancels server-owned movement")
	kinematicRoot.CFrame = mock.CFrame.new()

	-- The clamp applies only to movement goals; initial grabs still require an in-range object.
	check(not remotes.BeginDrag.OnServerInvoke(kinematicActor, part,
		kinematicRoot.Position + mock.Vector3.new(config.MAX_GRAB_DISTANCE + 1, 0, 0)), "Far-away initial grabs remain rejected")
	print("Drag reach: " .. checks .. " checks passed")
end
