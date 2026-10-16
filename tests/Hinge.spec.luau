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
	local farResponse, farSpeed = geometry.driveSettings(config.FINISH_DISTANCE+1,baseSettings,config)
	check(near(farResponse,config.RESPONSIVENESS) and near(farSpeed,baseSettings.speed),"Distant attraction keeps its original response and speed")
	local previousResponse, previousSpeed = farResponse,farSpeed
	for _, fraction in {1,0.75,0.5,0.25,0} do
		local response, speed = geometry.driveSettings(config.FINISH_DISTANCE*fraction,baseSettings,config)
		check(response >= previousResponse and speed <= previousSpeed and speed >= 0 and speed <= baseSettings.speed,
			"Precision response rises smoothly while its speed stays within the original power limit")
		previousResponse, previousSpeed = response,speed
	end
	check(near(previousResponse,config.FINISH_RESPONSIVENESS) and near(previousSpeed,config.FINISH_MAX_SPEED*baseSettings.power),
		"At contact the precision settings are reached without increasing the force cap")
	local legacy = table.clone(config); legacy.FINISH_DISTANCE = 0
	local legacyResponse, legacySpeed = geometry.driveSettings(0,baseSettings,legacy)
	check(near(legacyResponse,config.RESPONSIVENESS) and near(legacySpeed,baseSettings.speed),"Zero precision distance restores the old controller")
	check(near(baseSettings.force,config.MAX_FORCE*config.POWER) and near(baseSettings.distance,config.MAX_PULL_DISTANCE*config.POWER),
		"Power scales absolute force and range instead of mass-compensating the attraction")
	config.POWER = 0.1; local weak = geometry.settings(config)
	local _, weakFinishSpeed = geometry.driveSettings(0,weak,config)
	check(near(weakFinishSpeed,config.FINISH_MAX_SPEED*0.1),"Weak power also reduces the final approach speed")
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
	local oldB = b.CFrame
	b.CFrame = mock.CFrame.new(5+config.FINISH_DISTANCE*0.25,0,0); step()
	check(position.Responsiveness > config.RESPONSIVENESS and orientation.Responsiveness == position.Responsiveness
		and position.MaxVelocity < baseSettings.speed,"The server enables slower precision control near the selected points")
	check(position.MaxForce == baseSettings.force and orientation.MaxTorque == baseSettings.torque
		and not position.RigidityEnabled and not orientation.RigidityEnabled,"Precision never bypasses the configured force and torque caps")
	check((position.Attachment0.Position-x).Magnitude < 0.0001 and (position.Attachment1.Position+x).Magnitude < 0.0001,
		"Precision control never offsets either selected point")
	b.CFrame = oldB; step()
	check(near(position.Responsiveness,config.RESPONSIVENESS) and near(position.MaxVelocity,baseSettings.speed),
		"Moving away from contact restores the ordinary pull settings")
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
	check(weld.HasWeld(a,b) and not weld.HasHinge(a,b) and weld.GetConnectionType(a,b) == "Weld",
		"Settled points always create a tracked rigid weld, including ordinary parts")
	local record = connection(a,b)
	check(record and record.ObjectWeld:IsA("WeldConstraint") and record.ObjectWeld.Part0 == a and record.ObjectWeld.Part1 == b,
		"Ordinary parts are held by a native WeldConstraint after attraction")
	check(not record:FindFirstChild("ObjectHinge") and not a:FindFirstChild("ObjectHingeAttachment1")
		and not b:FindFirstChild("ObjectHingeAttachment2"),"Point pulling creates no permanent hinge or external axle attachments")
	check(not a.HingePullPosition and not locks:IsLocked(a),"Successful capture removes the temporary pull")
	check(record.WeldPoint.Size.X == config.MARKER_SIZE and record.WeldPoint.Color == config.MARKER_COLOR,
		"Point-pull welding keeps the tool's configurable marker size and color")
	local c = target("HingeC",mock.Vector3.new(7.5,0,0))
	check(weld.Weld(b,c) and table.find(weld.GetIndirectConnections(a),c),"Point-pull and ordinary welds share graph queries")
	local grabbed,_,payload = remotes.DragRemotes.BeginDrag.OnServerInvoke(actor,a,a.Position)
	check(grabbed and #payload.assembly.parts == 3,"Dragging includes the entire welded group")
	remotes.DragRemotes.EndDrag.OnServerEvent:Fire(actor,a,payload.id)
	check(freeze.IsFrozen(a) and freeze.IsFrozen(c),"Freeze policies include the point-pull welded group")
	freeze.Unfreeze(a)
	check(weld.UnweldMarker(record.WeldPoint,actor.UserId),"The existing unweld API removes point-pull welds")
	check(not weld.HasWeld(a,b) and not record.Parent,"Removing a point-pull weld deletes its marker and updates the graph")
	weld.Unweld(b,c)
	check(second(a,b),"Connect points again for invalidation testing"); settle()
	record = connection(a,b); record.ObjectWeld:Destroy()
	check(not weld.HasWeld(a,b) and not record.Parent,"External weld destruction removes stale graph records")
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
		"A cancelled final check cannot commit an old weld")
	delayedCommit()
	check(second(a,b),"Start before native weld creation failure")
	mock.failNextClass = "WeldConstraint"; settle()
	check(not weld.HasWeld(a,b) and not locks:IsLocked(a) and not a:FindFirstChild("ObjectHingeAttachment1")
		and not b:FindFirstChild("ObjectHingeAttachment2"),"Weld construction failure leaves no permanent attachments or graph edge")
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
	local outerClick = tire.Position+x*tire.Size.X*0.5+mock.Vector3.new(0,0,1.7)
	accepted,reason,payload = use(tire,outerClick,x)
	local selectedPoint = payload.point
	check(accepted and (payload.part.CFrame:PointToWorldSpace(selectedPoint)-outerClick).Magnitude < 0.0001,
		"Selecting a prepared tire keeps the exact off-center click, including outside the mounting part")
	check(not modules.ObjectTargets.containsPoint(mount,outerClick),"Regression point lies outside the mounting part bounds")
	local moved = mock.Vector3.new(0,0.2,0)
	for _, part in {mount,tire} do part.CFrame = mock.CFrame.new(moved)*part.CFrame end
	local oppositePoint = mock.Vector3.new(3,platform.Position.Y,-1)
	accepted,reason,payload = use(platform,oppositePoint,x)
	check(accepted and reason == "Pulling" and (payload.point-selectedPoint).Magnitude < 0.0001,
		"Second click never reprojects the first point toward the other model")
	check((mount.HingePullPoint.WorldPosition-outerClick-moved).Magnitude < 0.0001
		and (platform.HingePullPoint.WorldPosition-oppositePoint).Magnitude < 0.0001,
		"Both physical attraction points retain their local positions even if a model moved between clicks")
	cancel.OnServerEvent:Fire(actor)
	check(use(platform,oppositePoint,x),"Select the platform before a prepared wheel")
	local secondClick = tire.Position+x*tire.Size.X*0.5+mock.Vector3.new(0,0,1.7)
	accepted,reason,payload = use(tire,secondClick,x)
	check(accepted and (payload.part1.CFrame:PointToWorldSpace(payload.point1)-secondClick).Magnitude < 0.0001,
		"A prepared mechanism selected second also keeps its exact clicked point")
	cancel.OnServerEvent:Fire(actor)
	local innerClick = tire.Position-x*tire.Size.X*0.5+mock.Vector3.new(0,0.25,0.3)
	check(use(tire,innerClick,-x),"Select the inner tire face for mounting without flipping the axle")
	local targetPoint = mock.Vector3.new(3,platform.Position.Y,-3)
	accepted,reason,payload = use(platform,targetPoint,x)
	check(accepted and reason == "Pulling" and payload.part == mount,"A prepared tire click selects its real mounting part")
	check(platform.Anchored and not mount.Anchored,"The jack remains fixed while the wheel moves")
	check(mount.HingePullPoint.Axis.X == -1 and platform.HingePullPoint.Axis.X == -1,
		"Mounting orientation keeps the clicked face's axle direction")
	local point0 = payload.part.CFrame:PointToWorldSpace(payload.point)
	local point1 = payload.part1.CFrame:PointToWorldSpace(payload.point1)
	check((point0-innerClick).Magnitude < 0.0001 and (point1-targetPoint).Magnitude < 0.0001,
		"Successful mounting uses both exact clicks rather than the closest mounting face")
	local delta = point1-point0
	for _, part in {mount,tire} do part.CFrame = mock.CFrame.new(delta)*part.CFrame end
	settle()
	check(weld.GetConnectionType(wheel,platform) == "Weld" and not weld.HasHinge(wheel,platform),
		"Prepared wheels get a rigid mount rather than a redundant external axle")
	check(wheel.WheelMotor == motor and motor.Attachment0.Parent == mount and motor.Attachment1.Parent == tire,
		"Prepared wheel's existing motor and attachments are preserved")
	check((connection(wheel,platform).WeldPoint.Position-targetPoint).Magnitude < 0.0001,
		"The permanent marker is created where the selected points converged")
	jack.Step(0.05)
	check(platform.Anchored and mount.Anchored and jack.IsSupported(wheel),"The jack adopts the newly mounted wheel")
	jack.RemovePlayer(actor); weld.Unweld(wheel,platform)
	check(not mount.Anchored and not tire.Anchored,"Removing support restores wheel dynamics")
	demo:Destroy(); floor:Destroy(); jackTool:Destroy(); mock.raycastQuery = nil
	print("Hinge tool: " .. checks .. " checks passed (mocked constraints and lifecycle; no force simulation)")
end
