return function(mock, modules)
	local checks = 0
	local function check(value, message) assert(value, message); checks += 1 end
	local function near(a, b, tolerance) return math.abs(a - b) <= (tolerance or 1e-6) end
	local function vectorNear(a, b, tolerance) return (a - b).Magnitude <= (tolerance or 1e-6) end
	local motion, config = modules.PhysicsTargetMotion, modules.DragConfig
	local zero = mock.Vector3.zero
	local function vector(x, y, z) return mock.Vector3.new(x, y or 0, z or 0) end
	local settings = motion.getSettings(modules.DragWeight.getPhysicsSettings(1, config).maxVelocity, config)
	check(near(settings.acceleration, config.PHYSICS_TARGET_ACCELERATION), "Acceleration settings apply at weight 1")
	check(near(settings.deceleration, config.PHYSICS_TARGET_DECELERATION), "Deceleration settings apply at weight 1")
	local light = motion.getSettings(modules.DragWeight.getPhysicsSettings(0.01, config).maxVelocity, config)
	local heavy = motion.getSettings(modules.DragWeight.getPhysicsSettings(10, config).maxVelocity, config)
	check(light.acceleration > settings.acceleration and settings.acceleration > heavy.acceleration,
		"Existing weight curve controls acceleration smoothly")
	check(light.responseTime < settings.responseTime and settings.responseTime < heavy.responseTime,
		"Lighter objects retain faster target response")
	check(light.maxSpeed <= config.PHYSICS_TARGET_MAX_SPEED and heavy.maxSpeed <= settings.maxSpeed,
		"Target speed is capped by both configuration and physical weight limit")
	local state = motion.new(vector(2, 3, 4))
	check(vectorNear(state.position, vector(2, 3, 4)) and state.velocity.Magnitude == 0
		and state.acceleration.Magnitude == 0, "Trajectory starts at the grab point with no accumulated momentum")
	motion.step(state, vector(100), 0, settings)
	check(vectorNear(state.position, vector(2, 3, 4)), "Zero delta time cannot move the target")
	motion.step(state, vector(100), -1, settings); motion.step(state, vector(100), 0/0, settings)
	check(vectorNear(state.position, vector(2, 3, 4)), "Invalid delta times cannot poison trajectory state")
	state = motion.new(zero)
	motion.step(state, vector(100), 1/60, settings)
	check(state.position.X > 0 and state.position.X < settings.maxSpeed / 60,
		"First frame starts moving without jumping to full speed")
	check(state.acceleration.Magnitude < settings.acceleration, "Acceleration itself rises gradually from zero")
	local reachedFastSpeed = false
	for _ = 1, 120 do
		local oldPosition, oldVelocity = state.position, state.velocity
		motion.step(state, vector(1000), 1/120, settings)
		check(state.velocity.Magnitude <= settings.maxSpeed + 1e-6
			and (state.velocity - oldVelocity).Magnitude * 120 <= math.max(settings.acceleration, settings.deceleration) + 1e-6
			and (state.position - oldPosition).Magnitude * 120 <= settings.maxSpeed + 1e-6,
			"Speed, acceleration and per-frame travel respect configured caps")
		if state.velocity.Magnitude > settings.maxSpeed * 0.9 then reachedFastSpeed = true end
	end
	check(reachedFastSpeed, "Smooth acceleration still reaches a fast cruising speed")
	local previous = state.velocity.X
	motion.step(state, vector(-1000), 1/120, settings)
	check(state.velocity.X > 0 and state.velocity.X < previous, "Reversing the cursor brakes rather than instantly reversing velocity")
	for _ = 1, 240 do motion.step(state, vector(-1000), 1/120, settings) end
	check(state.velocity.X < 0, "Target eventually follows a reversed goal")

	local function run(frames, dt, goal, options)
		local current = motion.new(zero)
		for _ = 1, frames do motion.step(current, goal, dt, options or settings) end
		return current
	end
	local at30 = run(30, 1/30, vector(1000))
	local at60 = run(60, 1/60, vector(1000))
	local at120 = run(120, 1/120, vector(1000))
	check(vectorNear(at30.position, at60.position) and vectorNear(at60.position, at120.position),
		"Target path is consistent across ordinary frame rates")
	local settled = run(600, 1/120, vector(10, 3, -2))
	check(vectorNear(settled.position, vector(10, 3, -2), 0.001) and settled.velocity.Magnitude < 0.001,
		"Target converges and comes to rest at a stationary 3D goal")
	local lightSettled = run(600, 1/120, vector(0.01), light)
	check(vectorNear(lightSettled.position, vector(0.01), 0.001), "Tiny movements on light objects remain stable")
	local softConfig = table.clone(config)
	softConfig.PHYSICS_TARGET_ACCELERATION_SMOOTH_TIME = 0.15
	local soft = motion.getSettings(config.PHYSICS_MAX_VELOCITY, softConfig)
	check(soft.responseTime >= soft.accelerationSmoothTime * 2, "Soft acceleration settings retain stable velocity feedback")
	local softSettled = run(1800, 1/120, vector(10), soft)
	check(vectorNear(softSettled.position, vector(10), 0.001) and softSettled.velocity.Magnitude < 0.001,
		"Increasing acceleration smoothing cannot produce growing oscillations")
	local stopped = motion.new(zero)
	local noSpeed = table.clone(settings); noSpeed.maxSpeed = 0
	motion.step(stopped, vector(1000), 1, noSpeed)
	check(stopped.position.Magnitude == 0, "A zero target speed freezes the intermediate target")
	local stall = motion.new(zero)
	motion.step(stall, vector(1000), 20, settings)
	check(stall.position.Magnitude <= settings.maxSpeed * 0.1 + 1e-6, "Long frame stalls cannot produce a large catch-up leap")
	local unsmoothed = table.clone(settings); unsmoothed.accelerationSmoothTime = 0
	local sharp = motion.new(zero)
	motion.step(sharp, vector(1000), 1/120, unsmoothed)
	check(near(sharp.acceleration.Magnitude, settings.acceleration), "Zero smoothing time applies the requested acceleration directly")
	motion.reset(sharp, vector(3))
	check(vectorNear(sharp.position, vector(3)) and sharp.velocity.Magnitude == 0 and sharp.acceleration.Magnitude == 0,
		"Reset clears motion history at a constrained boundary or new grab")

	-- Integration: target moves between remote packets, while the assembly remains physical.
	local actor = mock.player(501)
	local part = mock.part("SmoothPhysical", 0)
	part.Anchored = true; part:SetAttribute("weight", 1)
	mock.services.CollectionService:AddTag(part, "can-drag")
	local remotes, service = mock.services.ReplicatedStorage.DragRemotes, mock.services.RunService
	local accepted, _, payload = remotes.BeginDrag.OnServerInvoke(actor, part, part.Position)
	check(accepted and not payload.clientAuthoritative, "New trajectory retains server-owned physical dragging")
	local rig = part.DragSystemPhysicsRig
	remotes.UpdateDrag.OnServerEvent:Fire(actor, part, mock.CFrame.new(6, 0, 0), payload.id, false)
	check(vectorNear(rig.DragSystemAlignPosition.Position, zero), "A remote packet records the goal without jumping the intermediate target")
	service.PreSimulation:Fire(1/60)
	local firstPosition = rig.DragSystemAlignPosition.Position
	check(firstPosition.X > 0 and firstPosition.X < 6 and vectorNear(part.Position, zero),
		"Physical frame advances only the AlignPosition goal, never the assembly CFrame")
	service.PreSimulation:Fire(1/60)
	check(rig.DragSystemAlignPosition.Position.X > firstPosition.X, "Target keeps moving smoothly without another remote packet")
	for _ = 1, 120 do service.PreSimulation:Fire(1/60) end
	check(vectorNear(rig.DragSystemAlignPosition.Position, vector(6), 0.005), "Smoothed target reaches a valid stationary goal")
	remotes.UpdateDrag.OnServerEvent:Fire(actor, part, mock.CFrame.new(100, 0, 0), payload.id, false)
	for _ = 1, 120 do service.PreSimulation:Fire(1/60) end
	check(rig.DragSystemAlignPosition.Position.Magnitude <= config.PHYSICS_TARGET_MAX_LEAD + 1e-6
		and rig.DragSystemAlignPosition.Position.Magnitude <= config.MAX_GRAB_DISTANCE + 1e-6,
		"A blocked assembly cannot accumulate an arbitrarily distant target")
	actor.Character.HumanoidRootPart.CFrame = mock.CFrame.new(-20, 0, 0)
	service.PreSimulation:Fire(1/60)
	check((rig.DragSystemAlignPosition.Position - actor.Character.HumanoidRootPart.Position).Magnitude
		<= config.MAX_GRAB_DISTANCE + 1e-6, "Moving player reach still constrains the smoothed target every physical frame")
	remotes.EndDrag.OnServerEvent:Fire(actor, part, payload.id)
	service.PreSimulation:Fire(1/60)
	check(part.Anchored and not part.DragSystemPhysicsRig, "Ending a drag removes its trajectory and physical rig")
	actor.Character.HumanoidRootPart.CFrame = mock.CFrame.new()
	config.PHYSICS_TARGET_SMOOTHING_ENABLED = false
	accepted, _, payload = remotes.BeginDrag.OnServerInvoke(actor, part, part.Position)
	rig = part.DragSystemPhysicsRig
	remotes.UpdateDrag.OnServerEvent:Fire(actor, part, mock.CFrame.new(6, 0, 0), payload.id, false)
	check(accepted and vectorNear(rig.DragSystemAlignPosition.Position, vector(6)), "Disabled smoothing restores direct target updates exactly")
	service.PreSimulation:Fire(1/60)
	check(vectorNear(rig.DragSystemAlignPosition.Position, vector(6)), "Compatibility mode adds no per-frame interpolation")
	remotes.EndDrag.OnServerEvent:Fire(actor, part, payload.id)
	config.PHYSICS_TARGET_SMOOTHING_ENABLED = true
	accepted, _, payload = remotes.BeginDrag.OnServerInvoke(actor, part, part.Position)
	check(vectorNear(part.DragSystemPhysicsRig.DragSystemAlignPosition.Position, part.Position), "A new grab has no trajectory left from the previous drag")
	part:SetAttribute("weight", 0)
	remotes.EndDrag.OnServerEvent:Fire(actor, part, payload.id)
	accepted, _, payload = remotes.BeginDrag.OnServerInvoke(actor, part, part.Position)
	check(accepted and payload.clientAuthoritative and not part.DragSystemPhysicsRig, "Weight zero retains its instantaneous mode")
	remotes.EndDrag.OnServerEvent:Fire(actor, part, payload.id)
	part:SetAttribute("weight", 1)
	accepted, _, payload = remotes.BeginDrag.OnServerInvoke(actor, part, part.Position)
	remotes.UpdateDrag.OnServerEvent:Fire(actor, part, mock.CFrame.new(6, 0, 0), payload.id, false)
	rig = part.DragSystemPhysicsRig
	rig.DragSystemAlignPosition:Destroy()
	service.PreSimulation:Fire(1/60)
	check(part.Anchored and not part.DragSystemPhysicsRig and not modules.InteractionLocks:IsLocked(part),
		"Destroyed constraints end the trajectory and release the dragged group")
	print("Physics target motion: " .. checks .. " checks passed (trajectory and mocked engine)")
end
