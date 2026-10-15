return function(mock, modules, startDragRuntime, startWeldRuntime)
	local checks = 0
	local function check(condition, message)
		assert(condition, message)
		checks += 1
	end
	local function contains(list, value) return table.find(list, value) ~= nil end
	local graph = modules.ConnectionGraph.new()
	check(not graph:AddEdge("A", "A"), "Self-edges must be rejected")
	check(graph:AddEdge("A", "B") and graph:HasEdge("B", "A"), "Edges must be symmetric")
	check(not graph:AddEdge("B", "A"), "Duplicate edges must be rejected")
	graph:AddEdge("B", "C"); graph:AddEdge("C", "D"); graph:AddEdge("D", "A")
	check(#graph:GetConnected("A") == 3, "Cycles must terminate without repeats")
	check(#graph:GetIndirect("A") == 1 and contains(graph:GetIndirect("A"), "C"), "Indirect excludes self/direct neighbors")
	graph:AddEdge("A", "C")
	check(#graph:GetIndirect("A") == 0, "Direct neighbor remains direct even with an alternative long path")
	local snapshot = graph:GetDirect("A"); table.clear(snapshot)
	check(#graph:GetDirect("A") == 3, "API arrays must not expose internal state")
	graph:RemoveEdge("A", "C"); graph:RemoveEdge("A", "B"); graph:RemoveEdge("A", "D")
	check(#graph:GetConnected("A") == 0, "Deleting edges must disconnect components")
	for i = 1, 1000 do graph:AddEdge(i, i + 1) end
	check(#graph:GetConnected(1) == 1000 and #graph:GetIndirect(1) == 999, "Long chains use iterative traversal")

	local locks = modules.TargetLocks.new()
	local release = locks:TryAcquire({"A", "B", "A"})
	check(release ~= nil and locks:IsLocked("B"), "Reservations include every key")
	check(locks:TryAcquire({"B", "C"}) == nil and not locks:IsLocked("C"), "Conflict must not leave partial locks")
	local otherRelease = locks:TryAcquire({"C"})
	check(otherRelease ~= nil, "Independent groups can be reserved concurrently")
	release(); release(); otherRelease()
	check(not locks:IsLocked("A") and not locks:IsLocked("B"), "Release must be idempotent")

	local warnings = 0
	local registry = modules.ValidationRegistry.new("test", function() warnings += 1 end)
	check(registry:Check("a", "b", 7), "No extra conditions should allow welding")
	local unregister = registry:Register(function(a, b, id) return a == "a" and b == "b" and id == 7 end)
	check(registry:Check("a", "b", 7) and not registry:Check("a", "b", 8), "Validators receive targets and user ID")
	unregister(); unregister()
	for _, value in {false, "true", 1} do
		local remove = registry:Register(function() return value end)
		check(not registry:Check(), "Only strict true may authorize welding"); remove()
	end
	local removeNil = registry:Register(function() return nil end)
	check(not registry:Check(), "Nil must deny welding"); removeNil()
	local removeError = registry:Register(function() error("expected test error") end)
	check(not registry:Check() and warnings == 1, "Errors must deny rather than crash"); removeError()
	local ran = 0
	local removeLater
	local removeFirst = registry:Register(function() removeLater(); return true end)
	removeLater = registry:Register(function() ran += 1; return true end)
	check(registry:Check() and ran == 1 and registry:Check() and ran == 1, "Registration changes affect the next evaluation")
	removeFirst()

	local collection = mock.services.CollectionService
	local function tagged(name, x)
		local part = mock.part(name, x)
		collection:AddTag(part, "can-weld")
		collection:AddTag(part, "can-drag")
		part.Anchored = true
		return part
	end
	local player = mock.player(101)
	local player2 = mock.player(102)
	local a, b, c = tagged("A", 0), tagged("B", 2.5), tagged("C", 5)
	local contact = modules.WeldGeometry.closestContact({a}, {b})
	check(math.abs(contact.distance - 0.5) < 1e-6, "Distance uses surfaces, not center spacing")
	local weld = modules.WeldServer
	local allowed, reason, nearest = weld.WeldNearest(a, player.UserId)
	check(allowed and reason == "Welded" and nearest == b, "One click selects the nearest other target")
	check(weld.HasWeld(a, b) and weld.HasWeld(b, a), "API must report the direct weld")
	check(not weld.TryWeld(a, b, player.UserId), "Existing direct weld must not be duplicated")
	check(weld.TryWeld(b, c, player.UserId), "Welding may extend a chain")
	check(#weld.GetDirectConnections(a) == 1 and contains(weld.GetIndirectConnections(a), c), "A-B-C exposes indirect A-C")
	check(not weld.HasWeld(a, c) and #weld.GetConnectedTargets(a) == 2, "Direct and transitive API queries differ")
	local folder = mock.workspace:FindFirstChild("WeldConnections")
	check(#folder:GetChildren() == 2, "Each direct weld has one record")
	local marker = folder:GetChildren()[1]:FindFirstChild("WeldPoint")
	check(marker and marker.Size.X == modules.WeldConfig.MARKER_SIZE and marker.Massless and not marker.CanCollide,
		"Weld marker must be configured and have no collision/mass contribution")
	local far = tagged("Far", 15)
	check(not weld.TryWeld(a, far, player.UserId), "Distance beyond the configured maximum must be rejected")
	local untagged = mock.part("Untagged", 1)
	check(not weld.TryWeld(a, untagged, player.UserId), "Both endpoints need can-weld")
	local deny = weld.RegisterWeldValidator(function(_, _, id) return id ~= player.UserId end)
	local d, e = tagged("D", 8), tagged("E", 10.5)
	check(not weld.TryWeld(d, e, player.UserId) and not weld.HasWeld(d, e), "Extra server conditions can deny welding")
	deny()
	check(weld.TryWeld(d, e, player.UserId), "Unregistering a condition must restore access")
	check(weld.RemoveWeld(d, e) and not weld.HasWeld(d, e), "API removal updates graph and constraints")

	local idleBeforeStart = tagged("IdleBeforeStart", -20)
	idleBeforeStart.Anchored = false
	idleBeforeStart:SetNetworkOwner(player2)
	startDragRuntime()
	check(idleBeforeStart:GetNetworkOwner() == nil and not idleBeforeStart:GetNetworkOwnershipAuto(),
		"Startup removes preexisting client ownership from unanchored interactive objects")
	local remotes = mock.services.ReplicatedStorage.DragRemotes
	local accepted, target, payload = remotes.BeginDrag.OnServerInvoke(player, a, a.Position)
	check(accepted and target == a and #payload.assembly.parts == 3, "Dragging captures the full welded chain")
	check(payload.collisionMode == "Collide" and payload.rotationMode == "CameraRelative",
		"Objects without mode attributes use collision and camera-relative rotation defaults")
	check(not a.Anchored and not b.Anchored and not c.Anchored, "Every member unanchors during dragging")
	check(payload.assembly.boxSize.X == 7, "Collision bounds cover the entire chain")
	check(not remotes.BeginDrag.OnServerInvoke(player2, c, c.Position), "A second player cannot grab another end of the chain")
	check(not weld.TryWeld(c, d, player.UserId), "Welding cannot change a group while it is being dragged")
	remotes.EndDrag.OnServerEvent:Fire(player, a, payload.id - 1)
	check(not a.Anchored, "An old session ID must not end the current drag")
	remotes.EndDrag.OnServerEvent:Fire(player, a, payload.id)
	check(a.Anchored and b.Anchored and c.Anchored, "Dropping restores original Anchored states for the full group")
	local denyGrab = modules.DragServer.RegisterGrabValidator(function(member) return member ~= c end)
	check(not remotes.BeginDrag.OnServerInvoke(player, a, a.Position), "Grab checks apply to every linked member")
	denyGrab()
	b:SetAttribute("weight", 0.01); c:SetAttribute("weight", 1)
	a:SetAttribute("DragCollisionMode", "NoClip")
	accepted, _, payload = remotes.BeginDrag.OnServerInvoke(player, a, a.Position)
	check(accepted and math.abs(payload.weight - 1.01) < 1e-9 and not payload.clientAuthoritative, "Group weight is summed and uses physics")
	check(not a.CanCollide and not b.CanCollide and not c.CanCollide, "Physics NoClip applies to every group member")
	check(weld.RemoveWeld(b, c), "Connections can be removed by a server script")
	mock.services.RunService.Heartbeat:Fire(0.25)
	check(a.Anchored and b.Anchored and c.Anchored and a.CanCollide and b.CanCollide and c.CanCollide,
		"Topology changes end dragging and restore physical properties")
	check(not modules.InteractionLocks:IsLocked(a) and not modules.InteractionLocks:IsLocked(c), "Topology cleanup releases all locks")
	check(#weld.GetIndirectConnections(a) == 0, "Broken chains stop reporting indirect links")
	b:Destroy()
	check(not weld.HasWeld(a, b) and #weld.GetDirectConnections(a) == 0, "Deleted endpoints remove stale links")

	local model = mock.Instance.new("Model"); model.Parent = mock.workspace
	local part0, part1 = mock.part("P0", 0, model), mock.part("P1", 1, model)
	local other = tagged("Other", 3.5)
	collection:AddTag(model, "can-weld"); collection:AddTag(model, "can-drag")
	check(weld.TryWeld(model, other, player.UserId), "Models can weld through their closest child part")
	check(model:FindFirstChild("WeldObjectRig") ~= nil, "Multi-part models stay assembled after welding")
	check(modules.ObjectTargets.findTagged(part1, "can-weld") == model, "A tagged model takes precedence over child parts")
	local record = folder:GetChildren()[1]
	local constraint = record:FindFirstChild("ObjectWeld")
	constraint:Destroy()
	check(not weld.HasWeld(model, other) and model:FindFirstChild("WeldObjectRig") == nil,
		"Destroying the main WeldConstraint cleans up the record, marker and internal rig")

	startWeldRuntime()
	local remote = mock.services.ReplicatedStorage.WeldNearest
	check(not remote.OnServerInvoke(player, model, part0.Position), "Remote welding requires the equipped tool")
	local tool = mock.Instance.new("Tool"); tool.Name, tool.Parent = "WeldTool", player2.Character
	check(remote.OnServerInvoke(player2, part0, part0.Position), "Equipped tool can weld a clicked model")
	check(not remote.OnServerInvoke(player2, part0, part0.Position), "Rapid repeated tool requests are limited")

	local f, g = tagged("F", 16), tagged("G", 18.5)
	local rejectNil = weld.RegisterWeldValidator(function() return nil end)
	check(not weld.TryWeld(f, g, player.UserId) and not modules.InteractionLocks:IsLocked(f), "Nil validator must release reservations")
	rejectNil()
	local rejectError = weld.RegisterWeldValidator(function() error("expected") end)
	check(not weld.TryWeld(f, g, player.UserId) and not weld.HasWeld(f, g), "Throwing validator must create no connection")
	rejectError()
	local deferWeld = weld.RegisterWeldValidator(function() coroutine.yield("waiting"); return true end)
	local weldResult
	local welding = coroutine.create(function() weldResult = {weld.TryWeld(f, g, player.UserId)} end)
	check(coroutine.resume(welding), "Weld validator can yield safely")
	check(not remotes.BeginDrag.OnServerInvoke(player2, f, f.Position), "Pending weld blocks conflicting grab")
	g.CFrame = mock.CFrame.new(30, 0, 0)
	check(coroutine.resume(welding) and not weldResult[1] and weldResult[2] == "TooFar", "Distance is checked again after a yielding validator")
	check(not modules.InteractionLocks:IsLocked(f), "Failed deferred weld releases its reservation")
	deferWeld()
	g.CFrame = mock.CFrame.new(18.5, 0, 0)
	local recordCount = #folder:GetChildren()
	mock.failNextClass = "Part"
	check(not weld.TryWeld(f, g, player.UserId), "Engine construction errors deny the operation")
	check(#folder:GetChildren() == recordCount and not weld.HasWeld(f, g)
		and not f:FindFirstChild("WeldObjectRig") and not g:FindFirstChild("WeldObjectRig"), "Partial weld construction rolls back all objects and rigs")
	check(weld.TryWeld(f, g, player.UserId), "Retry works after an interrupted construction")
	local deferGrab = modules.DragServer.RegisterGrabValidator(function(_, id)
		if id == player.UserId then coroutine.yield("waiting") end
		return true
	end)
	local grabResult
	local grabbing = coroutine.create(function() grabResult = {remotes.BeginDrag.OnServerInvoke(player, f, f.Position)} end)
	check(coroutine.resume(grabbing) and modules.InteractionLocks:IsLocked(f), "Pending grab reserves the whole component")
	player.CharacterRemoving:Fire()
	local replacementAccepted, _, replacementPayload = remotes.BeginDrag.OnServerInvoke(player2, f, f.Position)
	check(replacementAccepted, "Cancelled pending grab releases the component for another player")
	check(coroutine.resume(grabbing) and not grabResult[1] and modules.InteractionLocks:IsLocked(f),
		"Old cancelled request cannot grab or release a newer player's reservation")
	remotes.EndDrag.OnServerEvent:Fire(player2, f, replacementPayload.id)
	deferGrab()
	check(f.Anchored and g.Anchored and not modules.InteractionLocks:IsLocked(g), "Replacement drag cleans up original anchoring and locks")

	local boundary0, boundary1 = tagged("Boundary0", -8), tagged("Boundary1", -5)
	check(weld.TryWeld(boundary0, boundary1, player.UserId), "Gap exactly equal to maximum is allowed")
	local outside0, outside1 = tagged("Outside0", -16), tagged("Outside1", -12.999)
	check(not weld.TryWeld(outside0, outside1, player.UserId), "Gap just beyond the maximum is rejected")
	print("Welding: " .. checks .. " checks passed (mocked engine; no physics simulation)")
end
