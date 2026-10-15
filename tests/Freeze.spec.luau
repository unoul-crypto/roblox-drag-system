return function(mock, modules, startRuntime)
	local checks = 0
	local function check(value, message) assert(value, message); checks += 1 end
	local freeze, policies, config = modules.FreezeServer, modules.FreezePolicies, modules.FreezeConfig
	local collection, locks, weld = mock.services.CollectionService, modules.InteractionLocks, modules.WeldServer
	-- Clear prior integration fixtures, then start the policies and actual E remote.
	for _, target in freeze.GetFrozenModels() do freeze.Unfreeze(target) end
	startRuntime()
	local actor, other = mock.player(1101), mock.player(1102)
	local root, humanoid = actor.Character.HumanoidRootPart, actor.Character:FindFirstChildWhichIsA("Humanoid")
	local remotes, remote = mock.services.ReplicatedStorage.DragRemotes, mock.services.ReplicatedStorage.UnfreezeOwnModels
	local function target(name, x, freezable)
		local part = mock.part(name, x)
		collection:AddTag(part, "can-drag"); collection:AddTag(part, "can-weld")
		if freezable ~= false then collection:AddTag(part, config.TAG_NAME) end
		return part
	end
	local function grab(part, player)
		return remotes.BeginDrag.OnServerInvoke(player or actor, part, part.Position)
	end
	local function drop(part, payload, player)
		remotes.EndDrag.OnServerEvent:Fire(player or actor, part, payload.id)
	end
	local function tick()
		mock.clock += config.COLLISION_GRACE_TIME + 0.01
		policies.Step()
	end
	local events, reasons = {}, {}
	local connected = freeze.Frozen:Connect(function(part, userId, info)
		events[#events+1] = {part, userId, info.id}
	end)
	freeze.Unfrozen:Connect(function(_, _, reason) reasons[#reasons+1] = reason end)
	local part = target("FreezeDrop", 3)
	local ok, _, payload = grab(part)
	check(ok and not part.Anchored, "Freezable part can be physically grabbed")
	drop(part, payload)
	check(part.Anchored and freeze.IsFrozen(part), "Voluntary release freezes a freezable part")
	check(not part.DragSystemTemporaryRig and not locks:IsLocked(part), "Freezing leaves no drag rig or drag locks")
	check(#events == 1 and events[1][1] == part and events[1][2] == actor.UserId, "Freeze event identifies object and player")
	check(#freeze.GetFrozenModels(actor.UserId) == 1 and #freeze.GetFrozenModels(other.UserId) == 0,
		"API filters by the freezing player's identity")
	local info = freeze.GetFrozenInfo(part)
	info.members[1] = nil; info.parts[1] = nil
	check(#freeze.GetFrozenInfo(part).members == 1 and #freeze.GetFrozenInfo(part).parts == 1, "Returned snapshots cannot mutate API state")
	check(not freeze.Freeze(part, actor.UserId), "Duplicate freeze cannot replace ownership or emit another event")
	check(freeze.Unfreeze(part) and not part.Anchored and not freeze.IsFrozen(part), "API unfreeze enables physical falling")
	check(not freeze.Unfreeze(part), "Repeated unfreeze is harmless")
	part.Anchored = true
	check(freeze.Freeze(part, actor.UserId), "Originally anchored part can enter managed freezing")
	check(freeze.Unfreeze(part) and not part.Anchored, "Unfreeze explicitly releases even originally anchored parts")
	local plain = target("NoFreezeTag", 5, false)
	ok, _, payload = grab(plain); drop(plain, payload)
	check(not plain.Anchored and not freeze.IsFrozen(plain), "Object without can-freeze falls on release")
	local deny = freeze.RegisterFreezeValidator(function() return false end)
	ok, _, payload = grab(part); drop(part, payload)
	check(not freeze.IsFrozen(part) and not part.Anchored, "Custom conditions can deny automatic freezing")
	deny()
	deny = freeze.RegisterFreezeValidator(function() return nil end)
	check(not freeze.Freeze(part, actor.UserId) and not locks:IsLocked(part), "Nil condition fails closed and releases reservations")
	deny()
	deny = freeze.RegisterFreezeValidator(function() error("condition failed") end)
	check(not freeze.Freeze(part, actor.UserId) and not locks:IsLocked(part), "Throwing condition fails closed")
	deny()
	connected:Disconnect()
	local beforeEvents = #events
	check(freeze.Freeze(part, actor.UserId) and #events == beforeEvents, "Event callbacks can disconnect")
	freeze.Unfreeze(part)

	-- Group eligibility, one quota entry, and re-grab order.
	local a, b, c = target("FreezeChainA", 8), target("FreezeChainB", 10.5), target("FreezeChainC", 13)
	check(weld.Weld(a,b) and weld.Weld(b,c), "Prepare indirect freeze group")
	collection:RemoveTag(c, config.TAG_NAME)
	ok, _, payload = grab(a); drop(a,payload)
	check(not freeze.IsFrozen(a) and not a.Anchored and not b.Anchored and not c.Anchored,
		"One missing can-freeze tag denies freezing of the entire group")
	collection:AddTag(c, config.TAG_NAME)
	ok, _, payload = grab(a); drop(a,payload)
	check(a.Anchored and b.Anchored and c.Anchored and freeze.IsFrozen(c), "Full linked group freezes together")
	check(#freeze.GetFrozenModels(actor.UserId) == 1 and #freeze.GetFrozenInfo(b).members == 3,
		"A welded chain consumes one slot and API resolves any member")
	ok, _, payload = grab(c, other)
	check(ok and not freeze.IsFrozen(a) and not a.Anchored and #freeze.GetFrozenModels(actor.UserId) == 0,
		"Successful re-grab by another player unfreezes the previous owner's full group")
	drop(c,payload,other)
	check(#freeze.GetFrozenModels(other.UserId) == 1, "Releasing a re-grabbed group records the new owner")
	check(freeze.Unfreeze(b) and not a.Anchored and not b.Anchored and not c.Anchored, "Unfreezing any linked member releases the group")
	check(freeze.Freeze(a, actor.UserId), "Freeze before topology change")
	check(weld.Unweld(b,c), "Topology can change while frozen")
	tick()
	check(not freeze.IsFrozen(a) and not a.Anchored and not b.Anchored and not c.Anchored,
		"Changing a frozen graph releases all original members without stale anchors")

	-- Voluntary release thaws all older owned groups; direct API creation retains its FIFO limit.
	local max = config.MAX_FROZEN_MODELS
	local quota = {}
	for index = 1,max do
		quota[index] = target("Quota" .. index, index)
		check(freeze.Freeze(quota[index], actor.UserId), "Fill configured freeze slots")
	end
	local nextPart = target("QuotaNext", 7)
	local rejectGrab = modules.DragServer.RegisterGrabValidator(function() return false end)
	check(not grab(nextPart) and freeze.IsFrozen(quota[1]), "Rejected grab does not evict old frozen models")
	rejectGrab()
	ok, _, payload = grab(nextPart)
	check(ok and #freeze.GetFrozenModels(actor.UserId) == max and freeze.IsFrozen(quota[1]),
		"Grabbing a different model preserves old freezes until release")
	check(freeze.Freeze(part, other.UserId), "Prepare another player's frozen object")
	drop(nextPart, {id = payload.id - 1})
	check(#freeze.GetFrozenModels(actor.UserId) == max and not nextPart.Anchored,
		"Stale release cannot thaw existing models or end the active drag")
	drop(nextPart,payload)
	check(#freeze.GetFrozenModels(actor.UserId) == 1 and freeze.IsFrozen(nextPart) and nextPart.Anchored,
		"Releasing keeps only the newly frozen model, independently of the quota")
	for _, old in quota do check(not freeze.IsFrozen(old) and not old.Anchored, "Every older owned model is unanchored on release") end
	check(freeze.IsFrozen(part) and part.Anchored, "Releasing does not unfreeze another player's models")
	drop(nextPart, payload)
	check(freeze.IsFrozen(nextPart), "Repeated release cannot thaw the newly frozen model")
	freeze.UnfreezeAll(other.UserId)
	freeze.UnfreezeAll(actor.UserId)
	for _, old in quota do check(freeze.Freeze(old, actor.UserId), "Refill API quota") end
	local apiPart = target("QuotaAPI", 9)
	check(freeze.Freeze(apiPart, actor.UserId) and not freeze.IsFrozen(quota[1]), "Direct API freezing respects the FIFO limit")
	check(freeze.GetFrozenModels(actor.UserId)[1] == quota[2], "API lists frozen entries oldest first")
	freeze.UnfreezeAll(actor.UserId)
	check(freeze.Freeze(part, actor.UserId), "Freeze an old object before dropping a non-freezable one")
	ok, _, payload = grab(plain)
	check(ok and freeze.IsFrozen(part), "Grabbing a non-freezable model preserves existing freezes")
	drop(plain, payload)
	check(not freeze.IsFrozen(part) and not part.Anchored and #freeze.GetFrozenModels(actor.UserId) == 0,
		"Releasing a model without can-freeze still thaws all previous models")
	check(freeze.Freeze(part, actor.UserId), "Freeze before a denied release freeze")
	deny = freeze.RegisterFreezeValidator(function() return false end)
	ok, _, payload = grab(nextPart); drop(nextPart, payload)
	check(ok and not freeze.IsFrozen(part) and not part.Anchored and not freeze.IsFrozen(nextPart),
		"Custom freeze denial does not prevent old models thawing on release")
	deny()
	check(freeze.Freeze(a, actor.UserId), "Freeze a welded group before release")
	ok, _, payload = grab(nextPart); drop(nextPart, payload)
	check(ok and not freeze.IsFrozen(a) and not a.Anchored and not b.Anchored and freeze.IsFrozen(nextPart),
		"Release also thaws every part of an older welded group")
	freeze.UnfreezeAll(actor.UserId)
	local stopWaiting = freeze.RegisterFreezeValidator(function(candidate)
		if candidate == part then coroutine.yield() end
		return true
	end)
	local pendingResult
	local waiting = coroutine.create(function() pendingResult = freeze.Freeze(part, actor.UserId) end)
	check(coroutine.resume(waiting) and locks:IsLocked(part), "Older freeze can be waiting on a condition")
	ok, _, payload = grab(nextPart); drop(nextPart, payload)
	check(ok and freeze.IsFrozen(nextPart) and not locks:IsLocked(part),
		"Release cancels older pending freezes before committing the new one")
	check(coroutine.resume(waiting) and not pendingResult and not freeze.IsFrozen(part) and freeze.IsFrozen(nextPart),
		"An older resumed condition cannot restore a freeze after another model was released")
	stopWaiting(); freeze.UnfreezeAll(actor.UserId)
	config.MAX_FROZEN_MODELS = 0
	check(not freeze.Freeze(part, actor.UserId), "Zero maximum disables freezing through the rules")
	config.MAX_FROZEN_MODELS = max

	check(freeze.Freeze(part, actor.UserId), "Freeze for distance rule")
	root.CFrame = mock.CFrame.new(100,0,0)
	tick(); check(not freeze.IsFrozen(part) and reasons[#reasons] == "Distance", "Walking out of range unfreezes owned models")
	root.CFrame = mock.CFrame.new()
	config.UNFREEZE_DISTANCE = 0
	check(freeze.Freeze(part, actor.UserId), "Freeze with disabled distance rule")
	root.CFrame = mock.CFrame.new(100,0,0)
	tick(); check(freeze.IsFrozen(part), "Zero distance setting disables distance-based removal")
	root.CFrame = mock.CFrame.new(); config.UNFREEZE_DISTANCE = 48
	freeze.UnfreezeAll(actor.UserId)
	local large = target("LargeBounds", 60); large.Size = mock.Vector3.new(100,2,2)
	check(freeze.Freeze(large, actor.UserId), "Distance uses nearest part bounds, not a large object's center")
	freeze.UnfreezeAll(actor.UserId)

	-- E transport cannot name another user's model or override the acting identity.
	check(freeze.Freeze(part, actor.UserId) and freeze.Freeze(nextPart, other.UserId), "Freeze models for two users")
	remote.OnServerEvent:Fire(actor, other.UserId, nextPart)
	check(not freeze.IsFrozen(part) and freeze.IsFrozen(nextPart), "E ignores spoofed identity/targets and only unfreezes own records")
	freeze.UnfreezeAll(other.UserId)
	check(freeze.Freeze(part, actor.UserId), "Freeze for E budget test")
	for _=1,config.REQUEST_BURST do remote.OnServerEvent:Fire(actor) end
	check(not freeze.IsFrozen(part), "Legitimate E release is accepted")
	check(freeze.Freeze(part, actor.UserId), "Re-freeze after E burst")
	remote.OnServerEvent:Fire(actor)
	check(freeze.IsFrozen(part), "Excess E requests are rate limited")
	mock.clock += 1/config.REQUEST_RATE + 0.01
	remote.OnServerEvent:Fire(actor)
	check(not freeze.IsFrozen(part), "E budget refills independently of freeze state")

	-- Server geometry detects new contacts, including stationary/anchored objects.
	local floor = target("InitialSupport", 3, false)
	mock.overlaps = {[part] = {floor}}
	check(freeze.Freeze(part, actor.UserId), "Freeze an object already resting against another part")
	tick(); check(freeze.IsFrozen(part), "Existing contact does not instantly cancel a freeze")
	mock.overlaps[part] = {}; tick()
	mock.overlaps[part] = {floor}; tick()
	check(not freeze.IsFrozen(part) and reasons[#reasons] == "Collision", "Separating and contacting again creates a new unfreezing collision")
	mock.overlaps = {}
	check(freeze.Freeze(part, actor.UserId), "Freeze for ignored-collider test")
	local obstacleModel = mock.Instance.new("Model"); obstacleModel.Parent = mock.workspace
	local obstacle = mock.part("ProtectedObstacle", 3, obstacleModel); obstacle.Anchored = true
	collection:AddTag(obstacleModel, config.IGNORE_COLLISION_TAG)
	mock.overlaps[part] = {obstacle}; tick()
	check(freeze.IsFrozen(part), "not-unfreeze on collider's model protects contact")
	mock.overlaps[part] = {}; tick()
	collection:RemoveTag(obstacleModel, config.IGNORE_COLLISION_TAG)
	mock.overlaps[part] = {obstacle}; tick()
	check(not freeze.IsFrozen(part), "A new contact with an unprotected anchored object unfreezes")
	mock.overlaps = {}
	check(freeze.Freeze(part, actor.UserId), "Freeze for noncollidable geometry")
	obstacle.CanCollide = false; mock.overlaps[part] = {obstacle}; tick()
	check(freeze.IsFrozen(part), "Noncollidable overlap is not a physical collision")
	obstacle.CanCollide = true
	freeze.Unfreeze(part); mock.overlaps = {}
	check(freeze.Freeze(a, actor.UserId), "Freeze connected pair for internal contact test")
	mock.overlaps[a] = {b}; tick()
	check(freeze.IsFrozen(a), "Frozen group's own parts cannot unfreeze one another")
	freeze.UnfreezeAll(actor.UserId); mock.overlaps = {}
	config.UNFREEZE_ON_COLLISION = false
	check(freeze.Freeze(part, actor.UserId), "Freeze with collision rule disabled")
	mock.overlaps[part] = {floor}; tick()
	check(freeze.IsFrozen(part), "Collision policy can be disabled")
	freeze.Unfreeze(part); mock.overlaps = {}; config.UNFREEZE_ON_COLLISION = true

	-- Pending validators cannot commit stale life, graph or player intent.
	local function defer(mutate, message)
		local unregister = freeze.RegisterFreezeValidator(function() coroutine.yield(); return true end)
		local result
		local thread = coroutine.create(function() result = {freeze.Freeze(part, actor.UserId)} end)
		check(coroutine.resume(thread) and locks:IsLocked(part), "Pending freeze reserves the object")
		mutate()
		check(coroutine.resume(thread) and not result[1] and not locks:IsLocked(part) and not freeze.IsFrozen(part), message)
		unregister(); humanoid.Health = 100; root.CFrame = mock.CFrame.new()
		if not collection:HasTag(part, config.TAG_NAME) then collection:AddTag(part, config.TAG_NAME) end
	end
	defer(function() freeze.UnfreezeAll(actor.UserId) end, "UnfreezeAll cancels a pending freeze")
	defer(function() remote.OnServerEvent:Fire(actor) end, "E cancels a pending freeze, not just existing records")
	defer(function() humanoid.Health = 0 end, "Death during a condition denies the pending freeze")
	defer(function() collection:RemoveTag(part, config.TAG_NAME) end, "Tag is rechecked after a condition waits")
	local unregister = freeze.RegisterFreezeValidator(function() coroutine.yield(); return true end)
	local result
	local thread = coroutine.create(function() result = freeze.Freeze(part, actor.UserId) end)
	check(coroutine.resume(thread), "Start deferred distance freeze")
	root.CFrame = mock.CFrame.new(100,0,0)
	check(coroutine.resume(thread) and not freeze.IsFrozen(part) and not part.Anchored,
		"Policy checks distance again when a waited freeze commits")
	unregister(); root.CFrame = mock.CFrame.new()
	check(freeze.Freeze(part, actor.UserId), "Freeze before owner dies")
	humanoid.Health = 0; tick()
	check(not freeze.IsFrozen(part), "Dead owner releases previously frozen models")
	humanoid.Health = 100
	check(freeze.Freeze(part, actor.UserId), "Freeze before tag removal")
	collection:RemoveTag(part, config.TAG_NAME); tick()
	check(not freeze.IsFrozen(part), "Removing can-freeze invalidates a frozen record")
	collection:AddTag(part, config.TAG_NAME)
	check(freeze.Freeze(part, actor.UserId), "Freeze before external unanchoring")
	part.Anchored = false; tick()
	check(not freeze.IsFrozen(part), "API drops stale records after another server script unanchors")
	local model = mock.Instance.new("Model"); model.Parent = mock.workspace
	local modelPart = mock.part("FreezeChild", 2, model)
	collection:AddTag(model, config.TAG_NAME)
	check(freeze.Freeze(model, actor.UserId), "Freeze a multi-part model")
	local newChild = mock.part("NewChild", 2, model); tick()
	check(not freeze.IsFrozen(model) and not modelPart.Anchored and not newChild.Anchored, "Changing model parts invalidates a freeze without orphaned anchors")
	check(freeze.Freeze(model, actor.UserId), "Freeze before model deletion")
	model:Destroy(); tick()
	check(not freeze.IsFrozen(model), "Deleted models are removed from API")
	check(freeze.Freeze(part, actor.UserId), "Freeze before player removal")
	mock.services.Players.PlayerRemoving:Fire(actor)
	check(not freeze.IsFrozen(part), "Player removal thaws owned models")
	print("Freeze: " .. checks .. " checks passed (mocked server and geometry queries)")
end
