return function(mock, modules)
	local checks = 0
	local function check(value,message) assert(value,message); checks += 1 end
	local function near(a,b) return math.abs(a-b) < 1e-6 end
	local config, collection = modules.DragConfig,mock.services.CollectionService
	local stability, weights = modules.PhysicsDragStability,modules.DragWeight
	local thin, cube = mock.Vector3.new(12,0.05,0.05),mock.Vector3.new(2,2,2)
	local weighted = weights.getPhysicsSettings(0.01,config)
	local normal = stability.getSettings(weighted,cube,config)
	for key, value in weighted do check(normal[key] == value,"Ordinary shapes retain their exact weight settings") end
	local limited = stability.getSettings(weighted,thin,config)
	check(limited.orientationResponsiveness <= config.PHYSICS_STABILITY_ORIENTATION_RESPONSIVENESS
		and limited.maxAngularVelocity <= config.PHYSICS_STABILITY_MAX_ANGULAR_VELOCITY,"Thin light models have bounded angular response and speed")
	check(limited.forceGravityMultiplier <= config.PHYSICS_STABILITY_FORCE_GRAVITY_MULTIPLIER
		and limited.maxVelocity <= config.PHYSICS_STABILITY_MAX_VELOCITY,"Thin models cannot use the original extreme light-body force and speed")
	local previous = weighted.orientationResponsiveness
	for _, aspect in {6,8,12,20,30,100} do
		local settings = stability.getSettings(weighted,mock.Vector3.new(aspect,1,1),config)
		check(settings.orientationResponsiveness <= previous and settings.orientationResponsiveness >= limited.orientationResponsiveness,
			"Shape limits blend monotonically without a response jump at the aspect threshold")
		previous = settings.orientationResponsiveness
	end
	local heavy = weights.getPhysicsSettings(100,config)
	local heavyThin = stability.getSettings(heavy,thin,config)
	for key, value in heavy do check(heavyThin[key] == value,"Stabilization never increases heavy-body limits") end
	local legacy = table.clone(config); legacy.PHYSICS_STABILITY_ENABLED = false
	local old = stability.getSettings(weighted,thin,legacy)
	for key, value in weighted do check(old[key] == value,"Disabling shape limits restores original tuning") end
	check(near(weighted.orientationResponsiveness,weights.getPhysicsSettings(0.01,config).orientationResponsiveness),"Shape tuning does not mutate shared weight results")
	check(stability.mass(0.00001) == 0.00001 and stability.mass(0.02) == 0.02 and stability.mass(0) > 0,
		"Tiny real masses are preserved without dividing by zero")
	-- Validate the anchor transformation independently of the force solver.
	for _, angle in {0,math.pi*0.5,math.pi,-math.pi*0.5} do
		local pose = mock.CFrame.new(2,3,4)*mock.CFrame.fromAxisAngle(mock.Vector3.yAxis,angle)
		for _, edge in {-5,0,5} do
			local grab = mock.Vector3.new(edge,0.025,0)
			local center = pose:PointToWorldSpace(mock.Vector3.new(-1,0,0))
			local force = stability.forcePoint(pose,center,grab,1)
			local click = pose:PointToWorldSpace(grab)
			check((pose:PointToWorldSpace(force)-center).Magnitude < 1e-6,"Stable force attachment lies at the actual assembly center")
			local start = stability.forceTarget(click,pose,grab,force)
			check((start-center).Magnitude < 1e-6,"Center goal starts at the actual center even for a rotated edge grab")
			local goal = click+mock.Vector3.new(0.3,0.5,-0.2)
			local centerGoal = stability.forceTarget(goal,pose,grab,force)
			check(((centerGoal-center)-(goal-click)).Magnitude < 1e-6,"Center error equals grab-point error without a cursor offset")
		end
	end
	local identity = mock.CFrame.new()
	local goal180 = mock.CFrame.fromAxisAngle(mock.Vector3.yAxis,math.pi)
	local firstRotation = stability.rotate(identity,goal180,1/60,2,0.1)
	local _, firstAngle = firstRotation:ToAxisAngle()
	check(firstAngle > 0 and firstAngle <= 2/60+1e-6,"A 180-degree target cannot jump beyond the angular speed limit")
	local function rotateFor(dt,count)
		local rotation = identity
		for _ = 1,count do rotation = stability.rotate(rotation,goal180,dt,2,0.1) end
		return rotation
	end
	local at30,at60,at120 = rotateFor(1/30,30),rotateFor(1/60,60),rotateFor(1/120,120)
	check((at30.XVector-at60.XVector).Magnitude < 1e-6 and (at60.XVector-at120.XVector).Magnitude < 1e-6,
		"Rotation trajectory is consistent across physical frame rates")
	local settled = rotateFor(1/60,300)
	check((settled.XVector-goal180.XVector).Magnitude < 1e-6,"A stationary angular goal eventually settles")
	local plus = mock.CFrame.fromAxisAngle(mock.Vector3.yAxis,math.rad(179))
	local minus = mock.CFrame.fromAxisAngle(mock.Vector3.yAxis,math.rad(-179))
	local crossed = stability.rotate(plus,minus,1/60,2,0.1)
	local _, originalError = plus:ToObjectSpace(minus):ToAxisAngle()
	local _, newError = crossed:ToObjectSpace(minus):ToAxisAngle()
	check(newError < originalError and originalError < math.rad(3),"Crossing the 180-degree boundary follows the short arc")
	check(stability.rotate(identity,goal180,0,2,0.1) == identity and stability.rotate(identity,goal180,0/0,2,0.1) == identity,
		"Invalid frame durations cannot rotate the goal")
	check(stability.rotate(identity,goal180,1/60,2,0) == goal180,"Zero response time restores direct rotation targets")
	-- Reproduce finite matrix drift that double-precision ideal rotations hide.
	local drifted = mock.CFrame.newWithMatrix(mock.Vector3.zero,{1.000001,0,0,0,0.999999,0,0,0,1.000001})
	local corrected = stability.rotate(drifted,goal180,1/60,2,0.1)
	check(near(corrected.XVector.Magnitude,1) and near(corrected.YVector.Magnitude,1)
		and near(corrected.ZVector.Magnitude,1),"Incremental constraint rotations remove matrix drift before it accumulates")
	local floatBuffer = buffer.create(4)
	local function floatFrame(value)
		local matrix = table.clone(value.matrix)
		for i,v in matrix do buffer.writef32(floatBuffer,0,v); matrix[i] = buffer.readf32(floatBuffer,0) end
		return mock.CFrame.newWithMatrix(mock.Vector3.zero,matrix)
	end
	local axis = mock.Vector3.new(0.3,0.4,0.5)
	for _, angle in {0,1e-9,1e-5,0.7,math.pi-1e-7,math.pi,math.pi+1e-7} do
		local goal = floatFrame(mock.CFrame.fromAxisAngle(axis,angle))
		local rotation = floatFrame(mock.CFrame.fromAxisAngle(axis,angle+1e-5))
		for _ = 1,240 do rotation = floatFrame(stability.rotate(rotation,goal,1/60,8,0.1)) end
		check(modules.ObjectTargets.isFiniteCFrame(rotation)
			and (rotation.XVector-goal.XVector).Magnitude < 1e-4
			and (rotation.YVector-goal.YVector).Magnitude < 1e-4,
			"Float32 rotations settle without invalid targets at tiny angles and the 180-degree boundary")
	end
	local actor = mock.player(502)
	local remotes, run = mock.services.ReplicatedStorage.DragRemotes,mock.services.RunService
	local bar = mock.part("ThinLightBar",0)
	bar.Size,bar.AssemblyMass = thin,0.00001
	bar.CFrame = mock.CFrame.new(0,3,4)*mock.CFrame.fromAxisAngle(mock.Vector3.yAxis,0.7)
	collection:AddTag(bar,"can-drag")
	local localPoint = mock.Vector3.new(5,0.025,0)
	for _, weight in {0.001,0.05,1} do
		bar:SetAttribute("weight",weight)
		local point = bar.CFrame:PointToWorldSpace(localPoint)
		local allowed,_,payload = remotes.BeginDrag.OnServerInvoke(actor,bar,point)
		check(allowed and not payload.clientAuthoritative,"Offset grabs remain server-owned physical drags")
		local rig = bar.DragSystemPhysicsRig
		local position, orientation = rig.DragSystemAlignPosition,rig.DragSystemAlignOrientation
		check(position.ApplyAtCenterOfMass == false and not position.RigidityEnabled and not orientation.RigidityEnabled,
			"Separate native attachments stabilize force location while controllers remain compliant")
		check((orientation.Attachment0.Position-localPoint).Magnitude < 0.0001 and position.Attachment0 ~= orientation.Attachment0,
			"A rotated off-center click is preserved separately from the force attachment")
		check((position.Position-position.Attachment0.WorldPosition).Magnitude < 1e-6
			and (position.Position-bar.AssemblyCenterOfMass).Magnitude < 1e-6,"Creating a center rig introduces no initial positional error")
		local settings = stability.getSettings(weights.getPhysicsSettings(weight,config),thin,config)
		check(near(position.MaxForce,bar.AssemblyMass*mock.workspace.Gravity*settings.forceGravityMultiplier)
			and position.Responsiveness == settings.positionResponsiveness and orientation.Responsiveness == settings.orientationResponsiveness,
			"Native controllers use shape-limited settings and the actual tiny mass")
		check(near(position.MaxVelocity,settings.maxVelocity) and near(orientation.MaxAngularVelocity,settings.maxAngularVelocity),
			"Both linear and angular speed limits are installed on the native constraints")
		local original = bar.CFrame
		local desired = mock.CFrame.new(0,1,0)*original*mock.CFrame.fromAxisAngle(mock.Vector3.yAxis,0.1)
		remotes.UpdateDrag.OnServerEvent:Fire(actor,bar,desired,payload.id,true)
		run.PreSimulation:Fire(1/60)
		check(bar.CFrame == original and bar.CanCollide and (orientation.Attachment0.Position-localPoint).Magnitude < 0.0001,
			"Movement stays physical without changing the CFrame, collisions or grab point")
		check((orientation.CFrame.XVector-original.XVector).Magnitude > 0 and (orientation.CFrame.XVector-desired.XVector).Magnitude > 0.001,
			"Edited rotation starts moving through a continuous goal instead of snapping to a remote packet")
		for _ = 1,120 do run.PreSimulation:Fire(1/60) end
		check((orientation.CFrame.XVector-desired.XVector).Magnitude < 0.0001,"Edited rotation eventually reaches its requested angle")
		bar.CFrame = original*mock.CFrame.fromAxisAngle(mock.Vector3.yAxis,0.3)
		run.PreSimulation:Fire(1/60)
		local requestedGrab = desired:PointToWorldSpace(localPoint)
		local actualGrab = bar.CFrame:PointToWorldSpace(localPoint)
		local anchorError = ((position.Position-position.Attachment0.WorldPosition)-(requestedGrab-actualGrab)).Magnitude
		-- The translational trajectory can retain a sub-millistud settling error.
		check(anchorError < 0.001,
			"After physical rotation the runtime compensates the actual angle rather than the requested angle: "..anchorError.." weight="..weight)
		local forceAttachment,grabAttachment = position.Attachment0,orientation.Attachment0
		remotes.EndDrag.OnServerEvent:Fire(actor,bar,payload.id)
		check(not bar:FindFirstChild("DragSystemPhysicsRig") and not modules.InteractionLocks:IsLocked(bar)
			and not forceAttachment.Parent and not grabAttachment.Parent,"Release cleans up both attachments and the stabilized rig")
	end
	bar:SetAttribute("weight",0.05)
	config.PHYSICS_TARGET_SMOOTHING_ENABLED = false
	local allowed,_,payload = remotes.BeginDrag.OnServerInvoke(actor,bar,bar.CFrame:PointToWorldSpace(localPoint))
	check(allowed and (bar.DragSystemPhysicsRig.DragSystemAlignPosition.Position-bar.AssemblyCenterOfMass).Magnitude < 1e-6,
		"Direct-target mode also starts from a correctly compensated center")
	remotes.EndDrag.OnServerEvent:Fire(actor,bar,payload.id)
	config.PHYSICS_TARGET_SMOOTHING_ENABLED = true
	config.PHYSICS_STABILITY_ENABLED = false
	allowed,_,payload = remotes.BeginDrag.OnServerInvoke(actor,bar,bar.CFrame:PointToWorldSpace(localPoint))
	check(allowed and near(bar.DragSystemPhysicsRig.DragSystemAlignOrientation.Responsiveness,weights.getPhysicsSettings(0.05,config).orientationResponsiveness),
		"The legacy tuning option is applied when creating a native rig")
	remotes.EndDrag.OnServerEvent:Fire(actor,bar,payload.id)
	config.PHYSICS_STABILITY_ENABLED = true
	bar.CFrame = mock.CFrame.new(0,3,4)
	bar.AssemblyCenterOfMass = bar.CFrame:PointToWorldSpace(mock.Vector3.new(-3,0,0))
	local other = mock.part("OffsetHeavyNeighbor",0)
	other.CFrame,other.Size = bar.CFrame*mock.CFrame.new(-7,0,0),mock.Vector3.new(2,0.05,0.05)
	for _, target in {bar,other} do collection:AddTag(target,"can-weld"); collection:AddTag(target,"can-drag") end
	check(modules.WeldServer.Weld(bar,other),"Create a thin welded group with an off-center root")
	allowed,_,payload = remotes.BeginDrag.OnServerInvoke(actor,bar,bar.CFrame:PointToWorldSpace(localPoint))
	check(allowed and #payload.assembly.parts == 2 and bar.DragSystemPhysicsRig.DragSystemAlignPosition.ApplyAtCenterOfMass == false
		and (bar.DragSystemPhysicsRig.DragSystemAlignPosition.Attachment0.WorldPosition-bar.AssemblyCenterOfMass).Magnitude < 1e-6,
		"Welded groups use their whole assembly's center instead of the selected root's position")
	remotes.EndDrag.OnServerEvent:Fire(actor,bar,payload.id)
	modules.WeldServer.Unweld(bar,other)
	allowed,_,payload = remotes.BeginDrag.OnServerInvoke(actor,bar,bar.CFrame:PointToWorldSpace(localPoint))
	local grabAttachment = bar.DragSystemPhysicsRig.DragSystemAlignOrientation.Attachment0
	bar.DragSystemPhysicsRig.DragSystemAlignPosition.Attachment0:Destroy()
	run.PreSimulation:Fire(1/60)
	check(allowed and not bar:FindFirstChild("DragSystemPhysicsRig") and not grabAttachment.Parent
		and not modules.InteractionLocks:IsLocked(bar),"Losing the separate force attachment ends the drag and releases all resources")
	bar:Destroy(); other:Destroy()
	print("Physics drag stability: "..checks.." checks passed (settings and geometry; no native force simulation)")
end
