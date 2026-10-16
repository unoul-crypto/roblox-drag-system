return function(mock, modules, startRuntime)
	local checks = 0
	local function check(value,message) assert(value,message); checks += 1 end
	local function near(a,b) return math.abs(a-b) < 0.0001 end
	local hinge, config, geometry = modules.HingeServer,modules.HingeConfig,modules.HingeGeometry
	local weld, freeze, jack, locks = modules.WeldServer,modules.FreezeServer,modules.JackServer,modules.InteractionLocks
	local collection = mock.services.CollectionService
	local actor, other = mock.player(1801),mock.player(1802)
	local humanoid, root = actor.Character:FindFirstChildWhichIsA("Humanoid"),actor.Character.HumanoidRootPart
	local tool = mock.Instance.new("Tool"); tool.Name,tool.Parent = config.TOOL_NAME,actor.Character
	local x = mock.Vector3.new(1,0,0)
	startRuntime()
	local remotes = mock.services.ReplicatedStorage
	local click, cancel, status = remotes.HingeToolClick,remotes.CancelHingeTool,remotes.HingeToolStatus
	local function target(name,position,parent)
		local part = mock.part(name,0,parent); part.CFrame = mock.CFrame.new(position)
		for _, tag in {"can-weld","can-drag","can-freeze"} do collection:AddTag(part,tag) end
		return part
	end
	local function use(part,point,normal,player)
		mock.clock += 1
		return click.OnServerInvoke(player or actor,part,point or part.Position+x,normal or x)
	end
	local function second(a,b)
		check(use(a),"Select first surface")
		return use(b,b.Position-x,-x)
	end
	local function step(dt)
		mock.clock += dt or 0.05; hinge.Step()
	end
	local function settle()
		step(); step(config.SETTLE_TIME+0.01)
	end
	local function connection(a,b)
		for _, folder in mock.workspace.WeldConnections:GetChildren() do
			if folder.Target0.Value == a and folder.Target1.Value == b then return folder end
		end
	end
	local a,b = target("HingeA",mock.Vector3.new(3,0,0)),target("HingeB",mock.Vector3.new(6.5,0,0))
	local e0,e1 = {target=a,part=a,point=x,axis=x},{target=b,part=b,point=-x,axis=mock.Vector3.yAxis}
	b.CFrame = mock.CFrame.new(5,0,0)
	check(not geometry.ready(e0,e1,config),"Coincident points cannot capture with misaligned axes")
	e1.axis = x
	check(geometry.ready(e0,e1,config),"Coincident settled points with a common axis can capture")
	b.AssemblyAngularVelocity = mock.Vector3.new(0,0,5)
	check(not geometry.ready(e0,e1,config),"Point velocity includes rotation around the body's center")
	b.AssemblyAngularVelocity = mock.Vector3.zero; b.CFrame = mock.CFrame.new(6.5,0,0)
	local baseSettings = geometry.settings(config)
	check(near(baseSettings.force,config.MAX_FORCE*config.POWER) and near(baseSettings.distance,config.MAX_PULL_DISTANCE*config.POWER),
		"Power scales absolute force and range instead of mass-compensating the attraction")
	config.POWER = 0.1; local weak = geometry.settings(config)
	check(weak.force < baseSettings.force and weak.distance < baseSettings.distance and weak.speed < baseSettings.speed,
		"Lower power reduces force, range and maximum speed")
	check(second(a,b) == false,"Weak mode cannot start a long-distance pull")
	cancel.OnServerEvent:Fire(actor)
	config.POWER = 0; check(second(a,b) == false,"Power zero disables attraction")
	cancel.OnServerEvent:Fire(actor); config.POWER = modules.ProductionHingeConfig.POWER
	check(not geometry.valid(nil) and not geometry.valid({target=a,part=a}),"Malformed endpoint data is rejected")
	tool.Parent = nil; check(not use(a),"Tool must be equipped"); tool.Parent = actor.Character
	humanoid.Health = 0; check(not use(a),"Dead players cannot select"); humanoid.Health = 100
	root.CFrame = mock.CFrame.new(100,0,0); check(not use(a),"Selection enforces server reach"); root.CFrame = mock.CFrame.new()
	mock.rayBlocker = {Instance=b}; check(not use(a),"Selection cannot pass through walls"); mock.rayBlocker = nil
	check(not use(a,a.Position+mock.Vector3.new(100,0,0)),"Forged far hit points are rejected")
	check(not use(a,a.Position+x,mock.Vector3.new(0/0,0,0)),"Non-finite axes are rejected")
	check(not use(a,a.Position+x,x*100),"Non-unit axes are rejected")
	local untagged = mock.part("NoHingePermission",2)
	check(not use(untagged),"Both models need the configured tag")
	check(use(a),"First click selects a valid point")
	local accepted,reason = use(a)
	check(not accepted and reason == "SameTarget","The second point must be on another model")
	cancel.OnServerEvent:Fire(actor)
	a.Anchored,b.Anchored = true,true
	check(second(a,b) == false,"Two anchored groups cannot be moved")
	cancel.OnServerEvent:Fire(actor); a.Anchored,b.Anchored = false,false
	local unlock = locks:TryAcquire({b})
	check(second(a,b) == false,"Existing interaction reservations are respected")
	cancel.OnServerEvent:Fire(actor); unlock()
	local reject = weld.RegisterWeldValidator(function() return false end)
	check(second(a,b) == false and not a:FindFirstChild("HingePullPoint"),"Weld conditions deny attraction before any rig is installed")
	reject(); cancel.OnServerEvent:Fire(actor)
	check(second(a,b),"Start a physical point pull")
	local position,orientation = a.HingePullPosition,a.HingePullOrientation
	check(position and orientation and not position.RigidityEnabled and not orientation.RigidityEnabled,
		"Attraction uses bounded compliant native constraints")
	check(position.MaxForce == baseSettings.force and position.MaxVelocity == baseSettings.speed
		and orientation.MaxTorque == baseSettings.torque,"Forces and velocity come from server config")
	check(position.ReactionForceEnabled and orientation.ReactionTorqueEnabled,"Both movable bodies react physically")
	local originalA,originalB = a.CFrame,b.CFrame
	step(0.1)
	check(a.CFrame == originalA and b.CFrame == originalB and a.CanCollide and b.CanCollide,
		"The server never teleports bodies or disables their collisions during attraction")
	check(locks:IsLocked(a) and locks:IsLocked(b),"Both complete groups are reserved while pulling")
	check(not remotes.DragRemotes.BeginDrag.OnServerInvoke(other,b,b.Position),"Another player cannot drag a pulling group")
	check(not freeze.Freeze(a,actor.UserId) and not weld.Weld(a,b),"Freeze and weld operations cannot race attraction")
	step(config.PULL_TIMEOUT+0.01)
	check(not weld.HasWeld(a,b) and status.lastClientEvent[3] == "TooWeak","Timeout never forces a remote hinge into existence")
	check(not locks:IsLocked(a) and not locks:IsLocked(b) and not a.HingePullPosition,"Timeout removes constraints and reservations")
	check(second(a,b),"Start again after timeout")
	b.CFrame = mock.CFrame.new(5,0,0) -- Simulated physical convergence; the engine adapter applies no forces.
	settle()
	check(weld.HasHinge(a,b) and weld.GetConnectionType(a,b) == "Hinge","Settled points create a tracked native hinge")
	local record = connection(a,b)
	check(record and record.ObjectHinge:IsA("HingeConstraint") and record.ObjectHinge.ActuatorType == mock.Enum.ActuatorType.None,
		"An ordinary pair receives a free hinge rather than a rigid weld")
	local attachment0,attachment1 = record.ObjectHinge.Attachment0,record.ObjectHinge.Attachment1
	check((attachment0.WorldPosition-attachment1.WorldPosition).Magnitude < config.CAPTURE_DISTANCE
		and attachment0.WorldAxis:Dot(attachment1.WorldAxis) > 0.99,"Hinge attachments share a point and axis")
	check(not a.HingePullPosition and not locks:IsLocked(a),"Successful capture removes the temporary pull")
	check(record.WeldPoint.Size.X == config.MARKER_SIZE,"Hinge uses its own configurable marker")
	local c = target("HingeC",mock.Vector3.new(7.5,0,0))
	check(weld.Weld(b,c) and table.find(weld.GetIndirectConnections(a),c),"Mixed hinge/weld chains share graph queries")
	local grabbed,_,payload = remotes.DragRemotes.BeginDrag.OnServerInvoke(actor,a,a.Position)
	check(grabbed and #payload.assembly.parts == 3,"Dragging includes the entire mixed connected group")
	remotes.DragRemotes.EndDrag.OnServerEvent:Fire(actor,a,payload.id)
	check(freeze.IsFrozen(a) and freeze.IsFrozen(c),"Freeze policies also include hinge-connected members")
	freeze.Unfreeze(a)
	check(weld.UnweldMarker(record.WeldPoint,actor.UserId),"The existing unweld API removes hinge markers")
	check(not weld.HasWeld(a,b) and not attachment0.Parent and not attachment1.Parent,
		"Removing a hinge destroys both owned attachments and updates the graph")
	weld.Unweld(b,c)
	check(second(a,b),"Connect points again for invalidation testing"); settle()
	record = connection(a,b); record.ObjectHinge.Attachment0:Destroy()
	check(not weld.HasHinge(a,b) and not record.Parent,"External attachment destruction removes stale graph records")
	b.CFrame = mock.CFrame.new(6.5,0,0)
	check(second(a,b),"Start before owner cancels")
	cancel.OnServerEvent:Fire(actor,other) -- An extra argument cannot cancel someone else's job.
	check(not locks:IsLocked(a) and not a.HingePullPoint,"Cancellation removes temporary points and locks")
	check(use(a),"Select before unequipping"); tool.Parent = nil; step(); tool.Parent = actor.Character
	check(use(b,b.Position-x,-x) and not b.HingePullPosition,"Unequipping clears the server's first selection")
	cancel.OnServerEvent:Fire(actor)
	check(second(a,b),"Start before death"); humanoid.Health = 0; step()
	check(not locks:IsLocked(a) and not a.HingePullPoint,"Death cancels attraction"); humanoid.Health = 100
	check(second(a,b),"Start before an unexpected displacement")
	b.CFrame = mock.CFrame.new(50,0,0); step()
	check(not locks:IsLocked(a) and not weld.HasWeld(a,b),"Excessive travel cancels instead of stretching a permanent constraint")
	b.CFrame = mock.CFrame.new(6.5,0,0)
	check(second(a,b),"Start before an external topology change")
	local extra = target("AddedDuringPull",mock.Vector3.new(8,0,0))
	check(weld.RemoveWeld(b,c) == false,"Unrelated graph operations are harmless")
	local childModel = mock.Instance.new("Model"); childModel.Parent = mock.workspace
	-- Change a source's membership by moving it out of Workspace.
	b.Parent = childModel; childModel.Parent = nil; step()
	check(not locks:IsLocked(a),"Removing an endpoint cancels its reservation")
	childModel.Parent = mock.workspace; b.Parent = mock.workspace; childModel:Destroy(); extra:Destroy()
	check(freeze.Freeze(a,actor.UserId),"Frozen input fixture")
	reject = modules.DragServer.RegisterGrabValidator(function(member) return member ~= a end)
	check(second(a,b) == false and freeze.IsFrozen(a),"Denied movement does not thaw the selected object")
	reject(); cancel.OnServerEvent:Fire(actor)
	check(second(a,b) and not freeze.IsFrozen(a),"An allowed pull thaws dynamic frozen input")
	cancel.OnServerEvent:Fire(actor)
	-- A condition may yield: cancellation must not leave rigs created after cleanup.
	local unregister = hinge.RegisterPullValidator(function() coroutine.yield(); return true end)
	check(use(a),"Select before yielding condition")
	local result
	local thread = coroutine.create(function() result = use(b,b.Position-x,-x) end)
	check(coroutine.resume(thread),"Start delayed pull condition")
	cancel.OnServerEvent:Fire(actor)
	check(coroutine.resume(thread) and not result and not locks:IsLocked(a) and not a.HingePullPoint,
		"Cancelled pending conditions cannot resurrect an old pull")
	unregister()
	local delayedGrab = modules.DragServer.RegisterGrabValidator(function() coroutine.yield(); return true end)
	check(use(a),"Select before a delayed grab condition")
	thread = coroutine.create(function() result = use(b,b.Position-x,-x) end)
	check(coroutine.resume(thread),"Pause during movement permission checks")
	cancel.OnServerEvent:Fire(actor)
	check(coroutine.resume(thread) and not result and not a.HingePullPoint and not locks:IsLocked(a),
		"Cancellation during preparation cannot create temporary rigs after cleanup")
	delayedGrab()
	local conditionCalls = 0
	local delayedCommit = weld.RegisterWeldValidator(function()
		conditionCalls += 1
		if conditionCalls == 2 then coroutine.yield() end
		return true
	end)
	check(second(a,b),"Start before a delayed final connection check")
	b.CFrame = mock.CFrame.new(5,0,0); step()
	thread = coroutine.create(function() step(config.SETTLE_TIME+0.01) end)
	check(coroutine.resume(thread),"Pause during final connection validation")
	cancel.OnServerEvent:Fire(actor)
	check(coroutine.resume(thread) and not weld.HasWeld(a,b) and not locks:IsLocked(a),
		"A cancelled final check cannot commit an old hinge")
	delayedCommit()
	check(second(a,b),"Start before native hinge creation failure")
	mock.failNextClass = "HingeConstraint"; settle()
	check(not weld.HasWeld(a,b) and not locks:IsLocked(a) and not a:FindFirstChild("ObjectHingeAttachment1")
		and not b:FindFirstChild("ObjectHingeAttachment2"),"Construction failure rolls back both external attachments and graph state")
	check(not a:FindFirstChild("WeldObjectRig") and not b:FindFirstChild("WeldObjectRig"),"Failed native connection releases retained model rigs")
	check(use(a),"Select before selection timeout")
	step(config.SELECTION_TIMEOUT+0.01)
	accepted,reason = use(b,b.Position-x,-x)
	check(accepted and reason == "Selected","Expired selections cannot start an unexpected old pull")
	cancel.OnServerEvent:Fire(actor)
	-- The actual prepared wheel keeps its native motor; the jack stays anchored throughout.
	local demo = modules.VehicleDemo.Spawn(mock.CFrame.new())
	local platform,wheel = demo.Platform,demo.FrontRight
	local mount,tire,motor = wheel.Mount,wheel.Tire,wheel.WheelMotor
	local jackTool = mock.Instance.new("Tool"); jackTool.Name,jackTool.Parent = modules.JackConfig.TOOL_NAME,actor.Character
	local floor = mock.part("HingeWorkshopFloor",0); floor.Anchored = true
	mock.raycastQuery = function(origin,_,params)
		return if params.RespectCanCollide then {Instance=floor,Position=mock.Vector3.new(origin.X,0,origin.Z),Normal=mock.Vector3.yAxis} else nil
	end
	check(jack.Place(actor,platform,platform.Position),"Install a jack under the actual platform")
	jack.Step(0.05)
	check(use(tire,tire.Position+x*tire.Size.X*0.5,x),"Select the tire of a prepared wheel")
	local targetPoint = mock.Vector3.new(3,platform.Position.Y,-3)
	accepted,reason,payload = use(platform,targetPoint,x)
	check(accepted and reason == "Pulling" and payload.part == mount,"A prepared tire click selects its real mounting part")
	check(platform.Anchored and not mount.Anchored,"The jack remains fixed while the wheel moves")
	check(mount.HingePullPoint.Axis.X == -1 and platform.HingePullPoint.Axis.X == -1,
		"The prepared mounting face points toward the platform instead of pulling the tire inside it")
	local point0 = payload.part.CFrame:PointToWorldSpace(payload.point)
	local point1 = payload.part1.CFrame:PointToWorldSpace(payload.point1)
	local delta = point1-point0
	for _, part in {mount,tire} do part.CFrame = mock.CFrame.new(delta)*part.CFrame end
	settle()
	check(weld.GetConnectionType(wheel,platform) == "Weld" and not weld.HasHinge(wheel,platform),
		"Prepared wheels get a rigid mount rather than a redundant external axle")
	check(wheel.WheelMotor == motor and motor.Attachment0.Parent == mount and motor.Attachment1.Parent == tire,
		"Prepared wheel's existing motor and attachments are preserved")
	jack.Step(0.05)
	check(platform.Anchored and mount.Anchored and jack.IsSupported(wheel),"The jack adopts the newly mounted wheel")
	jack.RemovePlayer(actor); weld.Unweld(wheel,platform)
	check(not mount.Anchored and not tire.Anchored,"Removing support restores wheel dynamics")
	demo:Destroy(); floor:Destroy(); jackTool:Destroy(); mock.raycastQuery = nil
	print("Hinge tool: " .. checks .. " checks passed (mocked constraints and lifecycle; no force simulation)")
end
