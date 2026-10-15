return function(mock, modules, startVehicleRuntime)
	local checks = 0
	local function check(value, message) assert(value, message); checks += 1 end
	local collection, config, vehicles = mock.services.CollectionService, modules.VehicleConfig, modules.VehicleServer
	local weld, locks = modules.WeldServer, modules.InteractionLocks
	local actor, stranger = mock.player(1001), mock.player(1002)
	local kit = modules.VehicleDemo.Spawn(mock.CFrame.new(), true)
	local platform, seat = kit.Platform, kit.DriverSeat
	local wheels = {kit.FrontLeft, kit.FrontRight, kit.RearLeft, kit.RearRight}
	local humanoid = actor.Character:FindFirstChildWhichIsA("Humanoid")
	local function sit(value)
		seat.Occupant = if value then humanoid else nil
		humanoid.SeatPart = if value then seat else nil
	end
	local function input(value)
		mock.clock += 1
		return vehicles.HandleInput(actor, seat, value)
	end
	local function allStopped()
		for _, wheel in wheels do if wheel.WheelMotor.AngularVelocity ~= 0 then return false end end
		return true
	end
	local motion = modules.VehicleMotion
	local x, up, forward = mock.Vector3.new(1,0,0), mock.Vector3.yAxis, mock.Vector3.new(0,0,-1)
	check(motion.wheelVelocity(x, forward, up, 10) == -10, "Axle direction produces forward rolling velocity")
	check(motion.wheelVelocity(-x, forward, up, 10) == 10, "Mirrored axle reverses motor sign")
	check(motion.wheelVelocity(up, forward, up, 10) == 0, "Vertical axle cannot drive a car")
	check(motion.wheelVelocity(x, forward, up, 0/0) == 0, "Invalid speed fails closed")
	check(motion.wheelVelocity(mock.Vector3.new(0/0,0,0), forward, up, 10) == 0, "Invalid axle fails closed")
	check(#weld.GetConnectedTargets(seat) == 5, "Demo graph contains platform and all four wheel modules")
	for _, wheel in wheels do
		check(wheel.PrimaryPart == wheel.Mount and modules.ObjectMechanisms.isPreserved(wheel), "Demo wheel has a declared mount")
		check(#wheel.WeldObjectRig:GetChildren() == 0, "Permanent rig does not rigidly weld the tire to its mount")
		local native
		for _, record in mock.workspace.WeldConnections:GetChildren() do
			local a, b = record.Target0.Value, record.Target1.Value
			if a == wheel or b == wheel then native = record.ObjectWeld; break end
		end
		check(native and (native.Part0 == wheel.Mount or native.Part1 == wheel.Mount), "External weld selects the wheel mounting part")
		check(not wheel.Tire.Anchored and wheel.Tire.CanCollide and wheel.Tire.CustomPhysicalProperties ~= nil,
			"Demo tires have unanchored collidable friction surfaces")
	end
	vehicles.Step()
	check(allStopped(), "Unoccupied demo does not accelerate")
	check(not input(true), "Standing next to a seat does not authorize driving")
	sit(true)
	check(input(true), "Actual living seat occupant can send W")
	vehicles.Step()
	for _, wheel in wheels do
		local motor = wheel.WheelMotor
		check(motor.AngularVelocity == -config.WHEEL_ANGULAR_SPEED and motor.MotorMaxTorque == config.MOTOR_MAX_TORQUE,
			"W powers every wheel in the connected group")
		check(motor.MotorMaxAcceleration == config.MOTOR_MAX_ACCELERATION, "Motor startup uses the configured acceleration")
		check(wheel.Tire:GetNetworkOwner() == nil and not wheel.Tire:GetNetworkOwnershipAuto(), "Vehicle remains server-owned")
	end
	check(not vehicles.HandleInput(stranger, seat, true), "Another player cannot control the occupied seat")
	vehicles.Step(); check(not allStopped(), "Other player's failed request does not stop the driver")
	check(input(false), "Release is valid input")
	vehicles.Step(); check(allStopped() and wheels[1].WheelMotor.MotorMaxTorque == config.BRAKE_TORQUE, "Releasing W brakes the wheels")
	check(not input(100000), "Client cannot choose motor velocity")
	check(input(true), "Driver resumes")
	mock.clock += config.INPUT_TIMEOUT + 0.01
	vehicles.Step(); check(allStopped(), "Missing keepalive stops motors")
	check(input(true), "Drive before exit")
	sit(false); vehicles.Step(); check(allStopped(), "Leaving seat immediately stops motors")
	sit(true); check(input(true), "Drive before death")
	humanoid.Health = 0; vehicles.Step(); check(allStopped(), "Dead occupant cannot keep driving")
	humanoid.Health = 100
	check(input(true), "Drive before disconnecting a wheel")
	check(weld.Unweld(platform, wheels[1]), "Remove direct connection to one wheel")
	vehicles.Step()
	check(wheels[1].WheelMotor.AngularVelocity == 0 and wheels[2].WheelMotor.AngularVelocity ~= 0,
		"Disconnected wheel stops while attached wheels keep driving")
	check(weld.Weld(platform, wheels[1]), "Wheel can reconnect without losing its hinge")
	vehicles.Step(); check(wheels[1].WheelMotor.AngularVelocity ~= 0, "Reconnected wheel is discovered without a new input packet")
	check(weld.Unweld(platform, seat), "Disconnect the driver seat")
	vehicles.Step(); check(allStopped(), "An isolated driver seat cannot drive former indirect links")
	check(weld.Weld(platform, seat), "Reconnect seat")
	vehicles.Step(); check(not allStopped(), "Reconnected seat sees the graph again")
	local release = locks:TryAcquire(modules.ObjectTargets.getLockKeys({platform}, {platform}))
	vehicles.Step(); check(allStopped(), "A pending operation on the chassis suspends driving")
	release(); vehicles.Step(); check(not allStopped(), "Unlocking restores valid intent")
	platform.Anchored = true; vehicles.Step(); check(allStopped(), "Anchored chassis cannot be driven")
	platform.Anchored = false
	seat.Disabled = true; vehicles.Step(); check(allStopped(), "Disabled seat stops driving")
	seat.Disabled = false; check(input(true), "Re-enable seat")
	collection:RemoveTag(wheels[1], config.WHEEL_TAG)
	vehicles.Step(); check(wheels[1].WheelMotor.AngularVelocity == 0 and wheels[1].WheelMotor.MotorMaxTorque == 0,
		"Removing wheel tag stops the formerly managed motor")
	collection:AddTag(wheels[1], config.WHEEL_TAG)
	wheels[1].WheelMotor.Enabled = false
	vehicles.Step(); check(wheels[1].WheelMotor.AngularVelocity == 0, "Disabled hinge is not driven")
	wheels[1].WheelMotor.Enabled = true
	local attachment = wheels[1].WheelMotor.Attachment1
	wheels[1].WheelMotor.Attachment1 = nil
	vehicles.Step(); check(wheels[1].WheelMotor.AngularVelocity == 0, "Incomplete hinge is not driven")
	wheels[1].WheelMotor.Attachment1 = attachment
	check(input(true), "Prepare for seat conflicts")
	local secondSeat = mock.Instance.new("Seat"); secondSeat.CFrame, secondSeat.Parent = mock.CFrame.new(0,3.5,2), mock.workspace
	collection:AddTag(secondSeat, "can-weld"); collection:AddTag(secondSeat, config.SEAT_TAG)
	check(weld.Weld(platform, secondSeat), "Add another controller seat")
	secondSeat.Occupant = stranger.Character:FindFirstChildWhichIsA("Humanoid")
	vehicles.Step(); check(allStopped(), "Two occupied controller seats cannot fight over the same motors")
	secondSeat.Occupant = nil; weld.Unweld(platform, secondSeat)
	local originalCharacter = actor.Character
	actor.Character = stranger.Character
	vehicles.Step(); check(allStopped(), "New character cannot inherit an old character's intent")
	actor.Character = originalCharacter
	check(input(true), "Restore driver")
	vehicles.RemovePlayer(actor); vehicles.Step(); check(allStopped(), "Player removal clears intent")
	mock.clock += 1
	for _ = 1, config.REQUEST_BURST do check(vehicles.HandleInput(actor, seat, true), "Configured driving input burst admitted") end
	check(not vehicles.HandleInput(actor, seat, false), "Excess vehicle input is rate limited")
	mock.clock += 1/config.REQUEST_RATE + 1e-6
	check(vehicles.HandleInput(actor, seat, false), "Driving input budget refills with time")

	-- Occupied seats must not be attached to a temporary drag rig, including after yielding validators.
	local remotes = mock.services.ReplicatedStorage.DragRemotes
	check(not remotes.BeginDrag.OnServerInvoke(actor, platform, platform.Position), "Occupied vehicle cannot be grabbed from its platform")
	check(not remotes.BeginDrag.OnServerInvoke(stranger, wheels[1], wheels[1].Tire.Position), "Occupied vehicle cannot be grabbed from a wheel")
	sit(false)
	local accepted, _, payload = remotes.BeginDrag.OnServerInvoke(actor, platform, platform.Position)
	check(accepted, "Empty car can be dragged as a single group")
	check(wheels[1].WheelMotor.Parent == wheels[1], "Dragging retains original hinge")
	vehicles.Step(); check(allStopped() and wheels[1].WheelMotor.MotorMaxTorque == 0, "Dragging disables motor torque during temporary locking")
	remotes.EndDrag.OnServerEvent:Fire(actor, platform, payload.id)
	check(wheels[1].WheelMotor.Parent == wheels[1] and #wheels[1].WeldObjectRig:GetChildren() == 0,
		"Dropping removes temporary welds and restores the original movable mechanism")
	check(modules.FreezeServer.IsFrozen(platform), "Freezable demo car freezes as one group after release")
	check(modules.FreezeServer.Unfreeze(platform), "Unfreeze demo car before driving it again")
	check(input(false) == false, "Standing player cannot renew driving input")
	local unregister = modules.DragServer.RegisterGrabValidator(function() coroutine.yield(); return true end)
	local result
	local thread = coroutine.create(function() result = remotes.BeginDrag.OnServerInvoke(actor, platform, platform.Position) end)
	check(coroutine.resume(thread), "Vehicle grab condition can wait")
	sit(true)
	-- Each of the six members invokes the yielding condition.
	while coroutine.status(thread) ~= "dead" do check(coroutine.resume(thread), "Resume vehicle grab condition") end
	check(not result and not locks:IsLocked(platform), "Sitting during a pending grab prevents construction of a temporary rig")
	unregister(); sit(false)

	local parts = modules.VehicleDemo.Spawn(mock.CFrame.new(30,0,0), false)
	check(#weld.GetConnectedTargets(parts.Platform) == 0, "Loose demo starts with independent weld graph entries")
	check(weld.Weld(parts.Platform, parts.FrontLeft), "Loose wheel can be assembled through the public API")
	parts.FrontRight.PrimaryPart = nil
	check(not weld.Weld(parts.Platform, parts.FrontRight), "Prepared mechanism without a mount cannot weld its tire instead")
	startVehicleRuntime()
	local remote = mock.services.ReplicatedStorage.VehicleControl
	sit(true); mock.clock += 1
	remote.OnServerEvent:Fire(actor, seat, true)
	mock.services.RunService.PreSimulation:Fire(1/60)
	check(not allStopped(), "Runtime remote connects to server input and simulation motor control")
	mock.services.Players.PlayerRemoving:Fire(actor)
	mock.services.RunService.PreSimulation:Fire(1/60)
	check(allStopped(), "Runtime player removal stops driving")
	sit(false)
	print("Vehicles: " .. checks .. " checks passed (mocked engine; no traction simulation)")
end
