return function(mock, modules)
	local checks = 0
	local function check(value, message) assert(value, message); checks += 1 end
	local config, collection = modules.DragConfig, mock.services.CollectionService
	local remotes, service = mock.services.ReplicatedStorage.DragRemotes, mock.services.RunService
	local actor, stranger = mock.player(801), mock.player(802)
	local root = actor.Character.HumanoidRootPart
	local function target(name, x, weight, anchored)
		local part = mock.part(name, x)
		part.Anchored = anchored ~= false
		part:SetAttribute("weight", weight or 0)
		collection:AddTag(part, "can-drag")
		return part
	end
	local function drop(part, payload) remotes.EndDrag.OnServerEvent:Fire(actor, part, payload.id) end
	local function owned(part) return part:GetNetworkOwner() == nil and not part:GetNetworkOwnershipAuto() end
	local part = target("SecureZero", 2, 0, false)
	part:SetAttribute("DragCollisionMode", "NoClip")
	check(owned(part), "Tagging an idle unanchored part immediately gives it manual server ownership")
	local accepted, _, payload = remotes.BeginDrag.OnServerInvoke(actor, part, part.Position)
	check(accepted and not payload.clientAuthoritative and owned(part), "Zero weight never gives the client physics authority")
	check(not part.CanCollide, "NoClip disables native collisions for instantaneous dragging as well")
	remotes.UpdateDrag.OnServerEvent:Fire(actor, part, mock.CFrame.new(6, 0, 0), payload.id)
	check(math.abs(part.Position.X - 6) < 1e-6, "Zero weight still reaches a valid target immediately on the server")
	part.AssemblyLinearVelocity, part.AssemblyAngularVelocity = mock.Vector3.new(10000, 0, 0), mock.Vector3.new(0, 10000, 0)
	service.PreSimulation:Fire(1/60)
	check(part.AssemblyLinearVelocity.Magnitude == 0 and part.AssemblyAngularVelocity.Magnitude == 0,
		"Instantaneous mode clears stale motion instead of allowing a velocity fling")
	part:SetNetworkOwner(stranger)
	service.PreSimulation:Fire(1/60)
	check(owned(part), "Every active frame reclaims unexpected external ownership")
	drop(part, payload)
	check(not part.Anchored and owned(part) and part.CanCollide,
		"Dropping an originally unanchored object retains server ownership and restores native collisions")
	part:SetNetworkOwnershipAuto()
	service.Heartbeat:Fire(0.25)
	check(owned(part), "Idle validation restores server ownership if automatic ownership is re-enabled")
	part.Anchored = true; part.Anchored = false
	check(owned(part), "Unanchoring a tagged object does not open an automatic-ownership window")
	local unrelated = mock.part("Unrelated", 4)
	unrelated:SetNetworkOwner(stranger)
	service.Heartbeat:Fire(0.25)
	check(unrelated:GetNetworkOwner() == stranger, "Ownership enforcement is scoped to tagged interaction objects")

	local model = mock.Instance.new("Model"); model.Parent = mock.workspace
	collection:AddTag(model, "can-drag")
	local child = mock.part("AddedAfterTag", 3, model)
	check(owned(child), "A child added to an already-tagged empty model becomes server-owned")
	local outside = mock.Instance.new("Model")
	local stored = mock.part("Stored", 3, outside)
	stored:SetNetworkOwner(stranger)
	collection:AddTag(outside, "can-weld")
	check(stored:GetNetworkOwner() == stranger, "A stored model is not operated on before entering Workspace")
	outside.Parent = mock.workspace
	check(owned(stored), "Moving a tagged model into Workspace claims its existing parts")
	collection:AddTag(outside, "can-drag"); collection:RemoveTag(outside, "can-weld")
	stored:SetNetworkOwner(stranger); service.Heartbeat:Fire(0.25)
	check(owned(stored), "Removing one interaction tag preserves enforcement of the other")
	collection:RemoveTag(outside, "can-drag")
	stored:SetNetworkOwner(stranger); service.Heartbeat:Fire(0.25)
	check(stored:GetNetworkOwner() == stranger, "Removing all interaction tags disconnects the ownership watcher")

	local originalCast, originalOverlap = mock.workspace.Blockcast, mock.workspace.GetPartBoundsInBox
	local casts = 0
	mock.workspace.Blockcast = function() casts += 1; return {Distance = 0.5} end
	mock.workspace.GetPartBoundsInBox = function() return {} end
	part.CFrame = mock.CFrame.new(2, 0, 0)
	part:SetAttribute("DragCollisionMode", "Collide")
	accepted, _, payload = remotes.BeginDrag.OnServerInvoke(actor, part, part.Position)
	remotes.UpdateDrag.OnServerEvent:Fire(actor, part, mock.CFrame.new(20, 0, 0), payload.id)
	check(accepted and casts > 0 and part.Position.X < 3 and owned(part),
		"A large zero-weight request is resolved against walls on the server")
	drop(part, payload)
	mock.workspace.Blockcast, mock.workspace.GetPartBoundsInBox = originalCast, originalOverlap
	part:SetAttribute("DragCollisionMode", "NoClip")
	part.CFrame = mock.CFrame.new(2, 0, 0)
	part:SetAttribute("weight", 1)
	config.WEIGHT_DRAG_MODE = "SmoothDamp"
	accepted, _, payload = remotes.BeginDrag.OnServerInvoke(actor, part, part.Position)
	check(accepted and not payload.clientAuthoritative and owned(part), "Positive-weight SmoothDamp also keeps server ownership")
	remotes.UpdateDrag.OnServerEvent:Fire(actor, part, mock.CFrame.new(10, 0, 0), payload.id)
	for _ = 1, 20 do remotes.UpdateDrag.OnServerEvent:Fire(actor, part, mock.CFrame.new(10, 0, 0), payload.id) end
	check(part.Position.X == 2, "Burst requests cannot advance the SmoothDamp simulation")
	service.PreSimulation:Fire(1/60)
	local first = part.Position.X
	check(first > 2 and first < 10 and math.abs(mock.services.TweenService.lastCall.smoothTime - 0.05) < 1e-6,
		"Server physical frame performs weight damping with the original smoothing time")
	service.PreSimulation:Fire(1/60)
	check(part.Position.X > first and part.Position.X < 10, "SmoothDamp continues between client packets")
	drop(part, payload)
	config.WEIGHT_DRAG_MODE = "Physics"

	local welded = target("SecureLinked", 4.5, 0, false)
	part.CFrame = mock.CFrame.new(2, 0, 0); part:SetAttribute("weight", 0)
	collection:AddTag(part, "can-weld"); collection:AddTag(welded, "can-weld")
	check(modules.WeldServer.Weld(part, welded), "Security fixture has a welded component")
	accepted, _, payload = remotes.BeginDrag.OnServerInvoke(actor, part, part.Position)
	check(accepted and owned(part) and owned(welded), "Every member of a dragged group is server-owned")
	drop(part, payload)
	check(modules.WeldServer.Unweld(part, welded) and owned(part) and owned(welded),
		"Splitting a group leaves both components server-owned")

	local far = target("SecureFar", 100, 0)
	for _, value in {0/0, math.huge, -math.huge} do
		root.CFrame = mock.CFrame.new(value, 0, 0)
		check(not remotes.BeginDrag.OnServerInvoke(actor, far, far.Position), "Non-finite character position cannot bypass initial reach")
	end
	root.CFrame = mock.CFrame.newWithMatrix(mock.Vector3.zero, {0/0, 0, 0, 0, 1, 0, 0, 0, 1})
	check(not modules.InteractionCharacter.getRoot(actor), "Non-finite character rotation is also rejected")
	root.CFrame = mock.CFrame.new()
	local fakeRoot = mock.Instance.new("Folder")
	root.Name = "SavedRoot"; fakeRoot.Name, fakeRoot.Parent = "HumanoidRootPart", actor.Character
	check(not remotes.BeginDrag.OnServerInvoke(actor, part, part.Position), "An unexpected root instance class fails closed")
	fakeRoot:Destroy(); root.Name = "HumanoidRootPart"
	for _, mode in {"Zero", "SmoothDamp", "Physics", "DirectPhysics"} do
		part:SetAttribute("weight", if mode == "Zero" then 0 else 1)
		config.WEIGHT_DRAG_MODE = if mode == "SmoothDamp" then "SmoothDamp" else "Physics"
		config.PHYSICS_TARGET_SMOOTHING_ENABLED = mode ~= "DirectPhysics"
		for _, path in {"Remote", "Frame", "Heartbeat"} do
			root.CFrame = mock.CFrame.new()
			part.CFrame = mock.CFrame.new(2, 0, 0)
			accepted, _, payload = remotes.BeginDrag.OnServerInvoke(actor, part, part.Position)
			check(accepted, "Valid actor still grabs in every drag mode")
			root.CFrame = mock.CFrame.new(0/0, 0, 0)
			if path == "Remote" then remotes.UpdateDrag.OnServerEvent:Fire(actor, part, mock.CFrame.new(10, 0, 0), payload.id)
			elseif path == "Frame" then service.PreSimulation:Fire(1/60)
			else service.Heartbeat:Fire(0.25) end
			check(not modules.InteractionLocks:IsLocked(part) and not part.DragSystemTemporaryRig,
				"Invalid character cancels the session and cleans up through every update path")
			check(part.Position.X == 2, "Invalid character updates cannot move the assembly")
		end
	end
	config.WEIGHT_DRAG_MODE, config.PHYSICS_TARGET_SMOOTHING_ENABLED = "Physics", true
	root.CFrame = mock.CFrame.new()
	local remove = modules.DragServer.RegisterGrabValidator(function()
		coroutine.yield(); return true
	end)
	local result
	local pending = coroutine.create(function() result = {remotes.BeginDrag.OnServerInvoke(actor, part, part.Position)} end)
	check(coroutine.resume(pending), "Delayed grab reserves its group")
	root.CFrame = mock.CFrame.new(0/0, 0, 0)
	check(coroutine.resume(pending) and not result[1] and not modules.InteractionLocks:IsLocked(part),
		"Character validity is rechecked after a yielding permission callback")
	remove(); root.CFrame = mock.CFrame.new()

	local weldA, weldB = target("FiniteWeldA", 6, 0), target("FiniteWeldB", 8.5, 0)
	collection:AddTag(weldA, "can-weld"); collection:AddTag(weldB, "can-weld")
	root.CFrame = mock.CFrame.new(0/0, 0, 0)
	check(not modules.WeldServer.Weld(weldA, weldB, actor.UserId), "Welding API rejects invalid character transforms")
	root.CFrame = mock.CFrame.new()
	check(modules.WeldServer.Weld(weldA, weldB, actor.UserId), "Finite actor still welds normally")
	root.CFrame = mock.CFrame.new(math.huge, 0, 0)
	check(not modules.WeldServer.Unweld(weldA, weldB, actor.UserId), "Unwelding API rejects invalid character transforms")
	root.CFrame = mock.CFrame.new()
	check(modules.WeldServer.Unweld(weldA, weldB, actor.UserId), "Finite actor still unwelds normally")
	local tool = mock.Instance.new("Tool"); tool.Name, tool.Parent = "WeldTool", actor.Character
	root.CFrame = mock.CFrame.new(0/0, 0, 0)
	check(not mock.services.ReplicatedStorage.WeldNearest.OnServerInvoke(actor, weldA, weldA.Position)
		and not modules.WeldServer.HasWeld(weldA, weldB), "Tool remote also rejects an invalid actor before welding")
	root.CFrame = mock.CFrame.new()
	check(modules.WeldServer.Weld(weldA, weldB, actor.UserId), "Unweld remote fixture creates a real connection")
	local marker
	for _, record in mock.workspace.WeldConnections:GetChildren() do
		if record.Target0.Value == weldA or record.Target1.Value == weldA then marker = record.WeldPoint; break end
	end
	tool:Destroy()
	tool = mock.Instance.new("Tool"); tool.Name, tool.Parent = "UnweldTool", actor.Character
	root.CFrame = mock.CFrame.new(math.huge, 0, 0)
	check(not mock.services.ReplicatedStorage.UnweldMarker.OnServerInvoke(actor, marker, marker.Position)
		and modules.WeldServer.HasWeld(weldA, weldB), "Tool remote cannot delete a weld with invalid actor coordinates")
	root.CFrame = mock.CFrame.new()
	local deferUnweld = modules.WeldServer.RegisterUnweldValidator(function() coroutine.yield(); return true end)
	pending = coroutine.create(function() result = {modules.WeldServer.Unweld(weldA, weldB, actor.UserId)} end)
	check(coroutine.resume(pending), "Unweld conditions can wait while retaining the component reservation")
	root.CFrame = mock.CFrame.new(0/0, 0, 0)
	check(coroutine.resume(pending) and not result[1] and modules.WeldServer.HasWeld(weldA, weldB)
		and not modules.InteractionLocks:IsLocked(weldA), "Invalid actor after a yielding condition leaves the weld intact and releases locks")
	deferUnweld(); root.CFrame = mock.CFrame.new()
	local blocked = target("OwnershipUnavailable", 3, 0)
	blocked._properties.canSetOwnership = false
	check(not remotes.BeginDrag.OnServerInvoke(actor, blocked, blocked.Position)
		and blocked.Anchored and not modules.InteractionLocks:IsLocked(blocked),
		"Unable to claim physics authority denies the grab and restores anchoring and locks")
	print("Interaction security: " .. checks .. " checks passed (mocked replication/engine)")
end
