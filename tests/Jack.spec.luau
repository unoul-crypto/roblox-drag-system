return function(mock, modules, startRuntime)
	local checks = 0
	local function check(value, message) assert(value, message); checks += 1 end
	local function near(a, b) return math.abs(a-b) < 0.015 end
	local jack, motion, config = modules.JackServer, modules.JackMotion, modules.JackConfig
	local weld, freeze, collection = modules.WeldServer, modules.FreezeServer, mock.services.CollectionService
	local actor, other = mock.player(1501), mock.player(1502)
	local root, humanoid = actor.Character.HumanoidRootPart, actor.Character:FindFirstChildWhichIsA("Humanoid")
	local tool = mock.Instance.new("Tool"); tool.Name, tool.Parent = config.TOOL_NAME, actor.Character
	local floor = mock.part("WorkshopFloor", 0)
	floor.Anchored, floor.Size, floor.CFrame = true, mock.Vector3.new(100, 1, 100), mock.CFrame.new(0, -0.5, 0)
	local noGround, hidden, normal = false, false, mock.Vector3.yAxis
	local selfOccluder
	local looseGroundHits, groundCalls, lastGroundOrigin = {}, 0, nil
	local function excluded(part, params)
		for _, value in params.FilterDescendantsInstances do
			if part == value or part:IsDescendantOf(value) then return true end
		end
		return false
	end
	mock.raycastQuery = function(origin, _, params)
		if params.RespectCanCollide then
			groundCalls += 1; lastGroundOrigin = origin
			for _, obstacle in looseGroundHits do
				if not excluded(obstacle, params) then return {Instance = obstacle, Position = obstacle.Position, Normal = normal} end
			end
			return if noGround or excluded(floor, params) or origin.Y <= 0 then nil
				else {Instance = floor, Position = mock.Vector3.new(origin.X, 0, origin.Z), Normal = normal}
		end
		if hidden then return {Instance = floor} end
		if selfOccluder then
			for _, excluded in params.FilterDescendantsInstances do
				if selfOccluder == excluded or selfOccluder:IsDescendantOf(excluded) then return nil end
			end
			return {Instance = selfOccluder}
		end
		return nil
	end
	local originalCast = mock.workspace.Shapecast
	local ceiling = false
	mock.workspace.Shapecast = function(_, part, direction, _, ...)
		assert(select("#", ...) == 0, "Shapecast cframeOverride and sizeOverride are not enabled yet!")
		local frame, size = part.CFrame, part.Size
		if ceiling and direction.Y > 0 then
			return {Distance = 0, Instance = floor, Normal = -mock.Vector3.yAxis}
		end
		local halfY = size.Y*0.5
		if part.Shape == mock.Enum.PartType.Cylinder then
			halfY = math.abs(frame.XVector.Y)*size.X*0.5
				+ math.sqrt((frame.YVector.Y*size.Y*0.5)^2 + (frame.ZVector.Y*size.Z*0.5)^2)
		end
		local bottom = frame.Position.Y - halfY
		-- Like native shapecasts, do not report a floor already intersecting the starting shape.
		if direction.Y < 0 and bottom >= 0 and bottom + direction.Y <= 0 then
			return {Distance = math.max(bottom, 0), Instance = floor, Normal = mock.Vector3.yAxis}
		end
		return nil
	end
	local function target(name, x, anchored)
		local part = mock.part(name, x or 3)
		part.Size, part.CFrame = mock.Vector3.new(6, 1, 6), mock.CFrame.new(x or 3, 0.5, 0)
		part.Anchored = anchored == true
		for _, tag in {"can-drag", "can-weld", "can-freeze"} do collection:AddTag(part, tag) end
		return part
	end
	local function waitStep(count)
		for _ = 1, count or 180 do mock.clock += 0.05; jack.Step(0.05) end
	end
	startRuntime()
	local remote = mock.services.ReplicatedStorage.PlaceJack
	local function place(part)
		mock.clock += 1
		return remote.OnServerInvoke(actor, part, part.Position)
	end
	local function control(model, action, player)
		mock.clock += 1
		return jack.HandleControl(player or actor, model, action)
	end

	check(motion.advance(2, 6, 0, config) == 2 and motion.advance(2, 6, 0/0, config) == 2,
		"Invalid simulation intervals cannot change jack height")
	local nextHeight = motion.advance(2, 6, 1/60, config)
	check(nextHeight > 2 and nextHeight <= 2 + config.LIFT_SPEED/60, "Lift speed is bounded")
	check(motion.advance(2, 2.001, 0.1, config) < 2.001, "Height converges without overshoot")
	local rotated = target("RotatedBounds", -10)
	rotated.CFrame = mock.CFrame.new(-10, 2, 0) * mock.CFrame.fromAxisAngle(mock.Vector3.new(0,0,1), math.pi/2)
	local minimum, maximum = motion.bounds({rotated})
	check(near(minimum.Y, -1) and near(maximum.Y, 5), "Support bounds account for rotated parts")

	local platform = target("JackPlatform")
	tool.Parent = nil
	check(not place(platform), "Placing requires the equipped tool")
	tool.Parent = actor.Character
	humanoid.Health = 0
	check(not place(platform), "Dead players cannot place a jack")
	humanoid.Health = 100
	hidden = true; check(not place(platform), "Placement through a wall is rejected"); hidden = false
	noGround = true; check(not place(platform), "A jack requires actual ground"); noGround = false
	normal = mock.Vector3.new(1,0,0)
	local slopeAllowed, slopeReason = place(platform)
	check(not slopeAllowed and slopeReason == "UnevenGround", "Sloped foundations have a specific failure reason")
	normal = mock.Vector3.yAxis
	floor.Anchored = false; check(not place(platform), "Moving/unanchored ground is rejected"); floor.Anchored = true
	root.CFrame = mock.CFrame.new(100,0,0); check(not place(platform), "Distant placement is rejected"); root.CFrame = mock.CFrame.new()
	check(not remote.OnServerInvoke(actor, platform, mock.Vector3.new(0/0,0,0)), "Malformed hit coordinates are rejected")
	mock.clock += 1
	check(not remote.OnServerInvoke(actor, {}, platform.Position), "Forged object values are rejected")
	local unlock = modules.InteractionLocks:TryAcquire({platform})
	check(not place(platform), "A dragged/locked platform cannot be jacked"); unlock()
	local unregistered = jack.RegisterJackValidator(function() return false end)
	check(not place(platform) and not platform.Anchored, "Custom server conditions can deny placement"); unregistered()
	mock.nativeConnected = {[platform] = {floor}}
	check(not place(platform), "Native welds to map geometry cannot be lifted"); mock.nativeConnected = nil
	platform.CFrame = mock.CFrame.new(3,0.38,0)
	check(place(platform), "Small existing floor penetration does not prevent installation")
	check(lastGroundOrigin.Y > platform.Position.Y + platform.Size.Y*0.5,
		"Ground search starts above the platform instead of inside an overlapping floor")
	jack.GetJack(platform):Destroy(); platform.CFrame = mock.CFrame.new(3,0.5,0)
	platform.CFrame = mock.CFrame.new(3,0.1,0)
	local blockedAllowed, blockedReason = place(platform)
	check(not blockedAllowed and blockedReason == "GroundBlocked", "Deep solid intersections are rejected with a specific reason")
	platform.CFrame = mock.CFrame.new(3,0.5,0)
	local floorWheel, floorSeat = mock.part("LooseFloorWheel", 3), mock.Instance.new("Seat")
	floorSeat.Parent, floorSeat.CFrame = mock.workspace, mock.CFrame.new(3,0.1,0)
	looseGroundHits = {floorWheel, floorSeat}
	local beforeGroundCalls = groundCalls
	check(place(platform), "Loose parts under a platform do not hide the fixed floor")
	check(groundCalls-beforeGroundCalls == 3 and not floorWheel.Anchored and not floorSeat.Anchored,
		"Ground search skips both loose hits without anchoring or moving them")
	jack.GetJack(platform):Destroy()
	noGround = true; check(not place(platform), "Loose parts alone cannot serve as a foundation"); noGround = false
	looseGroundHits = {}
	for index = 1, config.MAX_GROUND_RAY_HITS+2 do
		local obstacle = mock.part("GroundSearchObstacle" .. index, 3)
		table.insert(looseGroundHits, obstacle)
	end
	beforeGroundCalls = groundCalls
	local obstructedAllowed, obstructedReason = place(platform)
	check(not obstructedAllowed and obstructedReason == "GroundObstructed" and groundCalls-beforeGroundCalls == config.MAX_GROUND_RAY_HITS,
		"Skipping loose parts has a bounded server cost")
	for _, obstacle in looseGroundHits do obstacle:Destroy() end
	looseGroundHits = {}; floorWheel:Destroy(); floorSeat:Destroy()
	local demo = modules.VehicleDemo.Spawn(mock.CFrame.new())
	check(place(demo.Platform), "Jack installation works on the actual demo platform geometry")
	jack.GetJack(demo.Platform):Destroy(); demo:Destroy()
	check(freeze.Freeze(platform, actor.UserId), "Freeze fixture is created")
	check(place(platform), "A frozen platform can be taken over by a jack")
	local model = jack.GetJack(platform)
	check(model and platform.Anchored and not freeze.IsFrozen(platform), "Jack anchoring is separate from freeze records")
	check(model.Base.Raise and model.Base.Lower and model.Base.Remove, "All three standard controls are present")
	check(not place(target("SecondPlatform", -3)), "Each player has at most one jack")
	check(not modules.DragServer.CanGrab(platform, actor.UserId), "Supported platforms cannot be grabbed")
	check(not freeze.Freeze(platform, actor.UserId), "Freeze API cannot replace jack support")
	check(not control(model, "Remove", other), "Another player cannot remove this jack")
	root.CFrame = mock.CFrame.new(100,0,0)
	check(not control(model, "Raise"), "Prompt controls recheck reach on the server"); root.CFrame = mock.CFrame.new()
	hidden = true; check(not control(model, "Raise"), "Prompt controls recheck visibility"); hidden = false
	check(not control(model, "Teleport"), "Unknown control actions are rejected")
	local second = target("OtherJackPlatform", -3)
	local otherTool = mock.Instance.new("Tool"); otherTool.Name, otherTool.Parent = config.TOOL_NAME, other.Character
	check(remote.OnServerInvoke(other, second, second.Position), "Another player can service a different platform")
	check(not weld.Weld(platform, second), "Welding two independently supported groups is rejected")
	jack.RemovePlayer(other)
	local start = platform.Position.Y
	mock.services.RunService.PreSimulation:Fire(1/60)
	check(platform.Position.Y > start and platform.Position.Y-start <= config.LIFT_SPEED/60 + 1e-6,
		"Runtime lifts through simulation updates rather than teleporting immediately")
	waitStep()
	check(near(platform.Position.Y, start + config.DEFAULT_LIFT), "Platform reaches the configured initial lift")
	freeze.UnfreezeAll(actor.UserId)
	mock.overlaps = {[platform] = {root}}; modules.FreezePolicies.Step(); mock.overlaps = nil
	check(platform.Anchored and jack.IsSupported(platform), "E and collision freeze policies do not release a jack")
	local loose = target("ReleasedWhileBuilding", -5)
	local dragRemotes = mock.services.ReplicatedStorage.DragRemotes
	local grabbed, _, payload = dragRemotes.BeginDrag.OnServerInvoke(actor, loose, loose.Position)
	check(grabbed, "The player can still drag other parts during servicing")
	dragRemotes.EndDrag.OnServerEvent:Fire(actor, loose, payload.id)
	check(platform.Anchored and jack.IsSupported(platform), "Releasing another object does not remove jack support")
	freeze.Unfreeze(loose)
	check(control(model, "Raise"), "Owner can raise the platform another step")
	waitStep()
	check(near(platform.Position.Y, start + config.DEFAULT_LIFT + config.HEIGHT_STEP), "Height adjustment is applied")
	ceiling = true; control(model, "Raise")
	local beforeCeiling = platform.Position.Y; waitStep(20)
	check(near(platform.Position.Y, beforeCeiling), "A ceiling blocks upward movement")
	ceiling = false; waitStep()
	check(platform.Position.Y > beforeCeiling, "Movement resumes when the obstacle clears")
	check(control(model, "Lower"), "Owner can lower by one step"); waitStep()
	check(near(platform.Position.Y, start + config.DEFAULT_LIFT + config.HEIGHT_STEP), "Lowering respects the selected height")
	local wheel = mock.part("NewWheel", 6.5)
	wheel.CFrame = mock.CFrame.new(6.5, platform.Position.Y, 0)
	for _, tag in {"can-drag", "can-weld", "can-freeze"} do collection:AddTag(wheel, tag) end
	check(weld.Weld(platform, wheel), "Welding onto a jacked platform remains available")
	check(jack.IsSupported(wheel) and not modules.DragServer.CanGrab(wheel, actor.UserId),
		"A new welded member cannot bypass support before the next tick")
	waitStep(1)
	check(wheel.Anchored, "Newly welded parts are held along with the platform")
	local seat = mock.Instance.new("Seat")
	seat.CFrame, seat.Parent = mock.CFrame.new(3, platform.Position.Y+1, 0), mock.workspace
	collection:AddTag(seat, "can-weld")
	check(weld.Weld(platform, seat), "An empty seat can be attached during servicing")
	waitStep(1); seat.Occupant = humanoid; waitStep(1)
	check(platform.Anchored and seat.Anchored and jack.IsSupported(platform), "Sitting down does not remove the support")
	seat.Occupant = nil; weld.Unweld(platform, seat); waitStep(1)
	local offset = wheel.Position.Y-platform.Position.Y
	control(model, "Raise"); waitStep()
	check(near(wheel.Position.Y-platform.Position.Y, offset), "Attached parts move with the platform")
	check(weld.Unweld(platform, wheel), "Unwelding remains available during servicing")
	waitStep(1)
	check(not wheel.Anchored and not jack.IsSupported(wheel), "Detached groups are freed and can be dragged separately")
	check(wheel:GetNetworkOwner() == nil and not wheel:GetNetworkOwnershipAuto(), "Detached parts retain server ownership")
	check(weld.Weld(platform, wheel), "A detached part can be welded back")
	waitStep(1)
	-- The floor can also appear in an overlap query at the terminal wheel contact.
	mock.boundsQuery = function(frame, size)
		return if frame.Position.Y-size.Y*0.5 <= config.COLLISION_PADDING*2+0.001 then {floor} else {}
	end
	check(control(model, "Remove") and platform.Anchored, "Removing starts a controlled descent")
	waitStep(1)
	check(platform.Position.Y > start and platform.Anchored, "Descent does not drop the assembly instantly")
	waitStep()
	check(not jack.IsSupported(platform) and not model.Parent, "Ground contact removes the jack")
	check(not platform.Anchored and not wheel.Anchored, "Grounded release restores dynamic physics for the whole group")
	mock.boundsQuery = nil
	check(platform.Position.Y > start and wheel.Position.Y >= 1-0.01,
		"Attached wheels reach the floor before the platform and stop descent without sinking: " .. platform.Position.Y .. ", " .. wheel.Position.Y)
	check(modules.DragServer.CanGrab(platform, actor.UserId), "The assembly becomes draggable again")
	check(model.Base == nil, "Removed jack destroys its prompts and geometry")
	weld.Unweld(platform, wheel)

	-- Reproduce a real prepared wheel: a cylinder spun around its axle, with its own mount.
	platform.CFrame = mock.CFrame.new(3,0.5,0)
	check(place(platform), "Place a jack before attaching a round wheel")
	model = jack.GetJack(platform); waitStep()
	local module = mock.Instance.new("Model"); module.Name, module.Parent = "RoundWheel", mock.workspace
	module:SetAttribute(modules.ObjectMechanisms.PRESERVE_ATTRIBUTE, true)
	local mount, tire = mock.part("Mount", 6.3, module), mock.part("Tire", 7.1, module)
	mount.Size, mount.CFrame = mock.Vector3.new(0.7,1,1), mock.CFrame.new(6.3,3.1,0)
	tire.Shape, tire.Size = mock.Enum.PartType.Cylinder, mock.Vector3.new(1,4,4)
	tire.CFrame = mock.CFrame.new(7.1,2.1,0) * mock.CFrame.fromAxisAngle(mock.Vector3.new(1,0,0), math.pi/4)
	module.PrimaryPart = mount
	for _, tag in {"can-drag", "can-weld", "can-freeze"} do collection:AddTag(module, tag) end
	check(weld.Weld(platform, module), "Attach one prepared wheel near the floor")
	waitStep(1)
	selfOccluder = tire
	mock.boundsQuery = function() return {floor} end -- Enclosing tire box intersects the floor.
	check(control(model, "Lower"), "The attached wheel does not occlude its own jack controls")
	waitStep(60)
	check(model.Parent and near(tire.Position.Y, 2 + config.COLLISION_PADDING) and platform.Anchored,
		"F stops at real tire contact and keeps the jack in place")
	hidden = true
	check(not control(model, "Remove"), "A separate wall still blocks the controls after attachment")
	hidden = false
	check(control(model, "Raise"), "A grounded wheel can be raised again")
	waitStep(60)
	check(tire.Position.Y > 2.3, "Lifting away from the floor remains possible")
	check(control(model, "Lower"), "Lower the wheel back onto the floor")
	waitStep(60)
	local supportedHeight = platform.Position.Y
	check(control(model, "Remove"), "X is accepted after F has already reached the floor")
	waitStep(3)
	check(not model.Parent and not jack.IsSupported(platform) and not jack.IsSupported(module),
		"An already grounded wheel does not trap the jack")
	check(near(platform.Position.Y, supportedHeight) and not platform.Anchored and not mount.Anchored and not tire.Anchored,
		"Grounded removal frees every part at the reached height without lowering through the floor")
	selfOccluder, mock.boundsQuery = nil, nil
	local shapeCast = mock.workspace.Shapecast
	mock.workspace.Shapecast = function() return nil end
	mock.overlaps = {[tire] = {floor}} -- Small existing penetration cannot be recovered by a sweep alone.
	local distance, supported = modules.JackCollision.travel({tire}, {tire}, -0.05)
	check(distance == 0 and supported, "Existing exact floor overlaps are recognized as support")
	distance, supported = modules.JackCollision.travel({tire}, {tire}, 0.05)
	check(distance > 0 and not supported, "An initial ground overlap permits upward escape")
	floor.Anchored = false
	distance, supported = modules.JackCollision.travel({tire}, {tire}, -0.05)
	check(distance == 0 and not supported, "A loose object underneath is an obstruction, not fixed ground")
	floor.Anchored = true
	mock.overlaps, mock.workspace.Shapecast = nil, shapeCast
	weld.Unweld(platform, module); module:Destroy()

	-- Lifecycle and construction failures cannot leave orphaned anchors or reservations.
	platform.CFrame, platform.Anchored = mock.CFrame.new(3, 0.5, 0), true
	check(place(platform), "Originally anchored objects are supported")
	model = jack.GetJack(platform); waitStep(2); model:Destroy()
	check(not jack.IsSupported(platform) and platform.Anchored, "External jack destruction restores original anchor state")
	platform.Anchored = false; platform.CFrame = mock.CFrame.new(3,0.5,0)
	mock.failNextClass = "ProximityPrompt"
	check(not place(platform) and not platform.Anchored and not modules.InteractionLocks:IsLocked(platform),
		"Construction failure rolls back geometry, state and locks")
	check(#mock.workspace.VehicleJacks:GetChildren() == 0, "Failed creation leaves no orphan jack")
	check(place(platform), "A player can place again after creation failure")
	local compatibleCast = mock.workspace.Shapecast
	local castFailures = 0
	mock.workspace.Shapecast = function() castFailures += 1; error("Injected shape query failure") end
	waitStep(3)
	check(castFailures == 1 and not jack.IsSupported(platform) and not platform.Anchored,
		"Unexpected engine failure releases support once rather than spamming every simulation tick")
	mock.workspace.Shapecast = compatibleCast
	platform.CFrame = mock.CFrame.new(3,0.5,0)
	check(place(platform), "Player can install again after a failed native query")
	humanoid.Health = 0; waitStep(1)
	check(not jack.IsSupported(platform) and not platform.Anchored, "Death releases the supported assembly")
	humanoid.Health = 100; platform.CFrame = mock.CFrame.new(3,0.5,0)
	check(place(platform), "Place before loss of ground")
	floor.Anchored = false; waitStep(1)
	check(not jack.IsSupported(platform) and not platform.Anchored, "Destroyed or moving support cannot leave suspended objects")
	floor.Anchored = true; platform.CFrame = mock.CFrame.new(3,0.5,0)
	check(place(platform), "Place before player disconnect")
	mock.services.Players.PlayerRemoving:Fire(actor)
	check(not jack.IsSupported(platform) and not platform.Anchored, "Disconnect releases the assembly and removes the jack")
	local multi = mock.Instance.new("Model"); multi.Parent = mock.workspace
	local a, b = mock.part("JackModelA", 2, multi), mock.part("JackModelB", 4, multi)
	a.CFrame, b.CFrame = mock.CFrame.new(2,1,0), mock.CFrame.new(4,1,0)
	b.Anchored, multi.PrimaryPart = true, a
	collection:AddTag(multi, config.TARGET_TAG)
	check(place(a), "Clicking a child selects its tagged model")
	model = jack.GetJack(multi); waitStep()
	check(near(a.Position.Y, 1+config.DEFAULT_LIFT) and near(b.Position.Y, a.Position.Y), "All model parts move without changing relative pose")
	local added = mock.part("AddedDuringServicing", 3, multi)
	added.CFrame = mock.CFrame.new(3,a.Position.Y,0); waitStep(1)
	check(added.Anchored and jack.IsSupported(added), "Children added to a held model also become supported")
	added.Parent = mock.workspace; waitStep(1)
	check(not added.Anchored and not jack.IsSupported(added), "Removing a child restores its original anchor state")
	model:Destroy()
	check(not a.Anchored and b.Anchored and multi.PrimaryPart == a, "Releasing a model preserves mixed anchor states and PrimaryPart")

	-- Conditions may yield. Recheck character, graph, tool, and geometry after they return.
	local function deferred(change, message)
		platform.CFrame = mock.CFrame.new(3,0.5,0)
		mock.clock += 1
		local unregister = jack.RegisterJackValidator(function() coroutine.yield(); return true end)
		local allowed
		local thread = coroutine.create(function() allowed = remote.OnServerInvoke(actor, platform, platform.Position) end)
		check(coroutine.resume(thread), "Start delayed jack condition")
		change()
		check(coroutine.resume(thread) and not allowed and not jack.IsSupported(platform)
			and not platform.Anchored and not modules.InteractionLocks:IsLocked(platform), message)
		unregister()
	end
	deferred(function() tool.Parent = nil end, "Unequipping during a condition cancels placement")
	tool.Parent = actor.Character
	deferred(function() humanoid.Health = 0 end, "Death during a condition cancels placement")
	humanoid.Health = 100
	deferred(function() collection:RemoveTag(platform, config.TARGET_TAG) end, "Tag removal during a condition cancels placement")
	collection:AddTag(platform, config.TARGET_TAG)
	mock.clock += 1
	local successes = 0
	for _ = 1, 20 do if remote.OnServerInvoke(actor, platform, platform.Position) then successes += 1 end end
	check(successes == 1, "Burst requests cannot create duplicate jacks")
	model = jack.GetJack(platform)
	local oldHeight = model:GetAttribute("Height")
	mock.clock += 1
	local acceptedControls = 0
	for _ = 1, 20 do if jack.HandleControl(actor, model, "Raise") then acceptedControls += 1 end end
	check(acceptedControls == config.REQUEST_BURST, "Prompt spam is limited before changing the requested height")
	waitStep()
	check(model:GetAttribute("Height") <= oldHeight + config.DEFAULT_LIFT + config.REQUEST_BURST*config.HEIGHT_STEP + 0.01,
		"Prompt requests also obey the server rate limit")
	for _ = 1, 30 do control(model, "Raise") end
	waitStep()
	check(near(model:GetAttribute("Height"), config.MAX_HEIGHT), "Repeated raises stop at the configured maximum")
	jack.RemovePlayer(actor)
	mock.workspace.Shapecast, mock.raycastQuery = originalCast, nil
	print("Jack: " .. checks .. " checks passed (mocked server, contacts and prompts)")
end
