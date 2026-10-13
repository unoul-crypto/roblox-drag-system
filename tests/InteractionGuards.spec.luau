return function(mock, modules)
	local checks = 0
	local function check(value, message) assert(value, message); checks += 1 end
	local limiter = modules.RequestLimiter.new(function() return mock.clock end)
	check(limiter:TryTake("a", 4, 2) and limiter:TryTake("a", 4, 2), "Configured burst is admitted")
	for _ = 1, 100 do check(not limiter:TryTake("a", 4, 2), "Spam cannot replenish tokens") end
	check(limiter:TryTake("b", 4, 2), "Players have independent buckets")
	mock.clock += 0.125
	check(not limiter:TryTake("a", 4, 2), "Partial token cannot admit a request")
	mock.clock += 0.125
	check(limiter:TryTake("a", 4, 2) and not limiter:TryTake("a", 4, 2), "Only elapsed server time replenishes tokens")
	mock.clock += 100
	check(limiter:TryTake("a", 4, 2) and limiter:TryTake("a", 4, 2)
		and not limiter:TryTake("a", 4, 2), "Long idle time cannot accumulate more than the burst")
	limiter:Remove("a")
	check(limiter:TryTake("a", 4, 2), "Departing actor bucket can be removed")
	check(not limiter:TryTake("invalid", 0, 2) and not limiter:TryTake("invalid", 0/0, 2), "Invalid limit configuration fails closed")

	local config, production = modules.DragConfig, modules.ProductionDragConfig
	config.BEGIN_REQUEST_BURST = production.BEGIN_REQUEST_BURST
	config.UPDATE_REQUEST_BURST = production.UPDATE_REQUEST_BURST
	modules.WeldConfig.REQUEST_INTERVAL = 0.25
	local remotes, collection = mock.services.ReplicatedStorage.DragRemotes, mock.services.CollectionService
	local function target(name, x)
		local part = mock.part(name, x); part.Anchored = true
		collection:AddTag(part, "can-drag"); collection:AddTag(part, "can-weld")
		return part
	end
	local actor, other = mock.player(901), mock.player(902)
	local part = target("Guards", 4)
	local accepted, _, payload = remotes.BeginDrag.OnServerInvoke(actor, part, part.Position)
	check(accepted, "First legitimate begin is admitted")
	accepted, _, payload = remotes.BeginDrag.OnServerInvoke(actor, part, part.Position)
	check(accepted, "Begin burst accommodates a quick retry")
	check(not remotes.BeginDrag.OnServerInvoke(actor, part, part.Position) and not part.Anchored,
		"Limited begin cannot end or replace an existing drag")
	for x = 1, production.UPDATE_REQUEST_BURST do
		remotes.UpdateDrag.OnServerEvent:Fire(actor, part, mock.CFrame.new(x, 0, 0), payload.id)
	end
	check(part.Position.X == production.UPDATE_REQUEST_BURST, "Valid update burst reaches the server")
	remotes.UpdateDrag.OnServerEvent:Fire(actor, part, mock.CFrame.new(20, 0, 0), payload.id)
	check(part.Position.X == production.UPDATE_REQUEST_BURST, "Excess movement request is discarded")
	mock.clock += 1/production.UPDATE_REQUEST_RATE + 1e-6
	remotes.UpdateDrag.OnServerEvent:Fire(actor, part, mock.CFrame.new(11, 0, 0), payload.id)
	check(part.Position.X == 11, "Updates resume after token refill")
	for _ = 1, 60 do
		mock.clock += 1/30
		remotes.UpdateDrag.OnServerEvent:Fire(actor, part, mock.CFrame.new(12, 0, 0), payload.id)
		check(part.Position.X == 12, "Normal 30 Hz updates stay below the server limit")
	end
	remotes.EndDrag.OnServerEvent:Fire(actor, part, payload.id)
	check(part.Anchored and not modules.InteractionLocks:IsLocked(part), "Drop succeeds after exhausting both limits")
	-- Exhaust the replenished begin bucket again before checking that drop cannot reset it.
	remotes.BeginDrag.OnServerInvoke(actor, nil, nil)
	remotes.BeginDrag.OnServerInvoke(actor, nil, nil)
	check(not remotes.BeginDrag.OnServerInvoke(actor, part, part.Position), "Releasing does not reset begin limits")
	accepted, _, payload = remotes.BeginDrag.OnServerInvoke(other, part, part.Position)
	check(accepted, "One player's spam does not throttle other players")
	remotes.EndDrag.OnServerEvent:Fire(other, part, payload.id)

	mock.clock += 1
	local humanoid = actor.Character:FindFirstChildWhichIsA("Humanoid")
	humanoid.Health = 0
	check(not remotes.BeginDrag.OnServerInvoke(actor, part, part.Position), "Dead character cannot begin dragging")
	check(not modules.WeldServer.WeldNearest(part, actor.UserId), "Dead character cannot scan for weld candidates")
	humanoid.Health = 100; humanoid.state = mock.Enum.HumanoidStateType.Dead
	check(not modules.InteractionCharacter.getRoot(actor), "Dead state is rejected even with positive health")
	humanoid.state = mock.Enum.HumanoidStateType.Running
	humanoid.Health = 0/0
	check(not modules.InteractionCharacter.getRoot(actor), "NaN health fails closed")
	humanoid.Health = 100
	mock.clock += 1
	accepted, _, payload = remotes.BeginDrag.OnServerInvoke(actor, part, part.Position)
	check(accepted, "Living character can drag")
	humanoid.Health = 0; humanoid.Died:Fire()
	check(part.Anchored and not modules.InteractionLocks:IsLocked(part), "Death immediately restores parts and releases drag locks")
	humanoid.Health = 100

	mock.clock += 1
	mock.rayBlocker = {Instance = mock.part("Wall", 2)}
	local validatorCalls = 0
	local disconnect = modules.DragServer.RegisterGrabValidator(function() validatorCalls += 1; return true end)
	check(not remotes.BeginDrag.OnServerInvoke(actor, part, part.Position) and validatorCalls == 0,
		"Hidden targets are rejected before invoking custom conditions")
	disconnect()
	mock.rayBlocker = nil
	local head = mock.part("Head", 0, actor.Character); head.CFrame = mock.CFrame.new(0, 2, 0)
	check(modules.InteractionVisibility.canSee(actor, part.Position, {part}), "Unobstructed point is visible")
	check(mock.lastRaycast.origin.Y == 2 and table.find(mock.lastRaycast.params.FilterDescendantsInstances, actor.Character)
		and table.find(mock.lastRaycast.params.FilterDescendantsInstances, part), "Ray uses server head and excludes own character and target")
	mock.clock += 1
	accepted, _, payload = remotes.BeginDrag.OnServerInvoke(actor, part, part.Position)
	check(accepted, "Visible target remains draggable")
	local position = part.Position.X
	mock.rayBlocker = {Instance = mock.part("Wall2", 2)}
	remotes.UpdateDrag.OnServerEvent:Fire(actor, part, mock.CFrame.new(18, 0, 0), payload.id)
	check(part.Position.X == position and not part.Anchored, "Hidden goal is ignored without dropping on a single rejected packet")
	mock.services.RunService.Heartbeat:Fire(0.25)
	check(part.Anchored and not modules.InteractionLocks:IsLocked(part), "A held object hidden by a wall is released during validation")
	mock.rayBlocker = nil

	local function deferredGrab(mutate, message)
		mock.clock += 1
		local unregister = modules.DragServer.RegisterGrabValidator(function() coroutine.yield(); return true end)
		local result
		local thread = coroutine.create(function() result = remotes.BeginDrag.OnServerInvoke(actor, part, part.Position) end)
		check(coroutine.resume(thread) and modules.InteractionLocks:IsLocked(part), "Yielding grab holds a reservation")
		mutate()
		check(coroutine.resume(thread) and not result and not modules.InteractionLocks:IsLocked(part), message)
		unregister(); mock.rayBlocker = nil; humanoid.Health = 100
	end
	deferredGrab(function() humanoid.Health = 0 end, "Death during a condition cancels pending grab")
	deferredGrab(function() mock.rayBlocker = {} end, "Visibility is rechecked after a yielding grab condition")
	local oldCharacter = actor.Character
	deferredGrab(function()
		actor.Character = mock.Instance.new("Model"); actor.Character.Parent = mock.workspace
		mock.part("HumanoidRootPart", 0, actor.Character)
		local replacementHumanoid = mock.Instance.new("Humanoid"); replacementHumanoid.Parent = actor.Character
		actor.CharacterAdded:Fire(actor.Character)
	end, "Respawning during a condition cannot complete an old character's grab")
	actor.Character = oldCharacter; actor.CharacterAdded:Fire(oldCharacter)
	mock.clock += 1
	accepted, _, payload = remotes.BeginDrag.OnServerInvoke(actor, part, part.Position)
	check(accepted, "Character watcher can bind again after a respawn")
	humanoid.Health = 0
	mock.services.RunService.PreSimulation:Fire(1/60)
	check(part.Anchored and not modules.InteractionLocks:IsLocked(part), "Simulation rejects zero health even without a Died event")
	humanoid.Health = 100

	local a, b = target("GuardWeldA", 12), target("GuardWeldB", 14.5)
	mock.rayBlocker = {}
	local ok, reason = modules.WeldServer.Weld(a, b, actor.UserId)
	check(not ok and reason == "NotVisible" and not modules.InteractionLocks:IsLocked(a), "Actor API cannot weld through a wall")
	check(modules.WeldServer.Weld(a, b), "Trusted server weld without an actor retains its API behavior")
	ok, reason = modules.WeldServer.Unweld(a, b, actor.UserId)
	check(not ok and reason == "NotVisible" and modules.WeldServer.HasWeld(a, b), "Actor API cannot unweld through a wall")
	mock.rayBlocker = nil
	humanoid.Health = 0
	ok, reason = modules.WeldServer.Unweld(a, b, actor.UserId)
	check(not ok and reason == "NotAlive", "Dead actor cannot unweld via API")
	humanoid.Health = 100
	check(modules.WeldServer.Unweld(a, b, actor.UserId), "Living visible actor can unweld")
	local function deferredWeld(unweld, mutate, expected)
		if unweld then check(modules.WeldServer.Weld(a, b), "Create connection for deferred unweld") end
		local unregister = (if unweld then modules.WeldServer.RegisterUnweldValidator else modules.WeldServer.RegisterWeldValidator)(function() coroutine.yield(); return true end)
		local result
		local operation = if unweld then modules.WeldServer.Unweld else modules.WeldServer.Weld
		local thread = coroutine.create(function() result = {operation(a, b, actor.UserId)} end)
		check(coroutine.resume(thread) and modules.InteractionLocks:IsLocked(a), "Deferred weld operation reserves endpoints")
		mutate()
		check(coroutine.resume(thread) and not result[1] and result[2] == expected and not modules.InteractionLocks:IsLocked(a),
			"Actor checks run again after yielding weld/unweld conditions")
		check(modules.WeldServer.HasWeld(a, b) == unweld, "Denied deferred operation leaves graph unchanged")
		unregister(); mock.rayBlocker = nil; humanoid.Health = 100
		if unweld then modules.WeldServer.Unweld(a, b) end
	end
	deferredWeld(false, function() humanoid.Health = 0 end, "NotAlive")
	deferredWeld(false, function() mock.rayBlocker = {} end, "NotVisible")
	deferredWeld(true, function() humanoid.Health = 0 end, "NotAlive")
	deferredWeld(true, function() mock.rayBlocker = {} end, "NotVisible")

	local weldRemote, unweldRemote = mock.services.ReplicatedStorage.WeldNearest, mock.services.ReplicatedStorage.UnweldMarker
	local tool = mock.Instance.new("Tool"); tool.Name, tool.Parent = "WeldTool", actor.Character
	mock.clock += 1
	check(not weldRemote.OnServerInvoke(actor, nil, nil), "Invalid tool request is rejected")
	ok, reason = unweldRemote.OnServerInvoke(actor, nil, nil)
	check(not ok and reason == "Busy", "Weld and unweld share their server cooldown")
	mock.clock += 0.25
	humanoid.Health = 0
	ok, reason = weldRemote.OnServerInvoke(actor, a, a.Position)
	check(not ok and reason == "NotAlive", "Tool remote rejects a dead actor")
	humanoid.Health = 100; mock.clock += 0.25; mock.rayBlocker = {}
	ok, reason = weldRemote.OnServerInvoke(actor, a, a.Position)
	check(not ok and reason == "NotVisible", "Tool remote rejects an occluded click")
	mock.rayBlocker = nil
	config.BEGIN_REQUEST_BURST = 10000; config.UPDATE_REQUEST_BURST = 10000
	print("Interaction guards: " .. checks .. " checks passed (mocked engine)")
end
