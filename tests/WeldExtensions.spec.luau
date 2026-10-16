return function(mock, modules)
	local checks = 0
	local function check(value, message) assert(value, message); checks += 1 end
	local collection = mock.services.CollectionService
	local weld, config = modules.WeldServer, modules.DragConfig
	local remotes = mock.services.ReplicatedStorage.DragRemotes
	local player, otherPlayer = mock.player(201), mock.player(202)
	local function target(name, x, draggable)
		local part = mock.part(name, x)
		part.Anchored = true
		collection:AddTag(part, "can-weld")
		if draggable then collection:AddTag(part, "can-drag") end
		return part
	end
	local function markerFor(a, b)
		for _, record in mock.workspace.WeldConnections:GetChildren() do
			local x, y = record.Target0.Value, record.Target1.Value
			if (x == a and y == b) or (x == b and y == a) then return record.WeldPoint end
		end
		error("Missing marker")
	end
	local function drop(actor, part, payload) remotes.EndDrag.OnServerEvent:Fire(actor, part, payload.id) end

	local a, b, c = target("PolicyA", -2, true), target("PolicyB", 0.5, true), target("PolicyC", 3, false)
	check(weld.Weld(a, b) and weld.Weld(b, c), "Server API welds specified objects without a player")
	check(not remotes.BeginDrag.OnServerInvoke(player, a, a.Position), "Default policy rejects an untagged indirect member")
	config.REQUIRE_ALL_MEMBERS_DRAGGABLE = false
	local accepted, _, payload = remotes.BeginDrag.OnServerInvoke(player, a, a.Position)
	check(accepted and #payload.assembly.parts == 3, "Disabled tag policy allows the group via its tagged source")
	collection:RemoveTag(b, "can-drag")
	check(not a.Anchored, "Disabled tag policy does not stop dragging on a secondary tag removal")
	drop(player, a, payload)
	local deny = modules.DragServer.RegisterGrabValidator(function(member) return member ~= c end)
	check(not remotes.BeginDrag.OnServerInvoke(player, a, a.Position), "Disabling tag policy preserves custom member conditions")
	deny()
	check(not remotes.BeginDrag.OnServerInvoke(player, c, c.Position), "The clicked source always needs can-drag")
	collection:AddTag(b, "can-drag"); collection:AddTag(c, "can-drag")
	accepted, _, payload = remotes.BeginDrag.OnServerInvoke(player, a, a.Position)
	collection:RemoveTag(a, "can-drag")
	check(accepted and a.Anchored, "Removing the source tag ends dragging even with policy disabled")
	collection:AddTag(a, "can-drag")
	config.REQUIRE_ALL_MEMBERS_DRAGGABLE = true
	accepted, _, payload = remotes.BeginDrag.OnServerInvoke(player, a, a.Position)
	collection:RemoveTag(c, "can-drag")
	check(accepted and a.Anchored and b.Anchored and c.Anchored, "Enabled policy stops dragging on any member tag loss")
	collection:AddTag(c, "can-drag")
	local deferGrab = modules.DragServer.RegisterGrabValidator(function(member)
		if member == a then coroutine.yield() end
		return true
	end)
	local result
	local grabbing = coroutine.create(function() result = {remotes.BeginDrag.OnServerInvoke(player, a, a.Position)} end)
	check(coroutine.resume(grabbing), "Pending member validation can yield")
	collection:RemoveTag(c, "can-drag")
	check(coroutine.resume(grabbing) and not result[1] and not modules.InteractionLocks:IsLocked(a),
		"Tag eligibility is checked again after a yielding validator")
	deferGrab(); collection:AddTag(c, "can-drag")

	local marker = markerFor(b, c)
	local x, y = weld.GetWeldTargets(marker)
	check(x == b and y == c and marker.CanQuery, "A selectable marker resolves to its exact endpoints")
	local forged = mock.part("WeldPoint", 0)
	forged:SetAttribute(modules.WeldConfig.MARKER_ATTRIBUTE, true)
	check(not weld.UnweldMarker(forged, player.UserId) and weld.HasWeld(b, c), "Copied marker names and attributes grant no authority")
	check(not weld.Unweld(a, c), "Unweld removes only a direct edge")
	check(not weld.Unweld(b, c, 999999), "Explicit actor must be an online player")
	for _, condition in {
		function() return false end,
		function() return nil end,
		function() error("expected denial") end,
	} do
		local remove = weld.RegisterUnweldValidator(condition)
		local allowed, reason = weld.Unweld(b, c)
		check(not allowed and reason == "Denied" and weld.HasWeld(b, c)
			and not modules.InteractionLocks:IsLocked(b), "Unweld conditions fail closed and release locks")
		remove(); remove()
	end
	accepted, _, payload = remotes.BeginDrag.OnServerInvoke(player, a, a.Position)
	local allowed, reason = weld.UnweldMarker(marker, otherPlayer.UserId)
	check(accepted and not allowed and reason == "Busy" and weld.HasWeld(b, c), "Unweld respects an active drag on the whole component")
	drop(player, a, payload)
	local seenActor
	local recordActor = weld.RegisterUnweldValidator(function(first, second, id)
		seenActor = id
		return first == b and second == c
	end)
	check(weld.UnweldMarker(marker, player.UserId) and seenActor == player.UserId, "Marker unweld conditions receive both objects and actor")
	recordActor()
	check(not weld.HasWeld(b, c) and marker.Parent == nil and weld.GetWeldTargets(marker) == nil
		and #weld.GetIndirectConnections(a) == 0, "Unweld removes the marker and updates every API query")
	local okA, _, stateA = remotes.BeginDrag.OnServerInvoke(player, a, a.Position)
	local okC, _, stateC = remotes.BeginDrag.OnServerInvoke(otherPlayer, c, c.Position)
	check(okA and okC and #stateA.assembly.parts == 2 and #stateC.assembly.parts == 1, "Disconnected groups can be dragged concurrently")
	drop(player, a, stateA); drop(otherPlayer, c, stateC)
	check(weld.Weld(b, c), "Disconnected objects can be welded again")
	marker = markerFor(b, c)
	local deferUnweld = weld.RegisterUnweldValidator(function() coroutine.yield(); return true end)
	local unwelding = coroutine.create(function() result = {weld.Unweld(b, c, player.UserId)} end)
	check(coroutine.resume(unwelding) and not remotes.BeginDrag.OnServerInvoke(otherPlayer, a, a.Position), "Pending unweld reserves the whole chain")
	player.Character.HumanoidRootPart.CFrame = mock.CFrame.new(100, 0, 0)
	check(coroutine.resume(unwelding) and not result[1] and result[2] == "OutOfReach"
		and weld.HasWeld(b, c), "Unweld reach is checked again after waiting")
	player.Character.HumanoidRootPart.CFrame = mock.CFrame.new()
	deferUnweld()

	-- Remote checks have no time dependency: switch only the harness's cloned config.
	modules.WeldConfig.REQUEST_INTERVAL = 0
	local remote = mock.services.ReplicatedStorage.UnweldMarker
	check(not remote.OnServerInvoke(player, marker, marker.Position), "Unweld remote requires its separate tool")
	local tool = mock.Instance.new("Tool"); tool.Name, tool.Parent = "UnweldTool", player.Character
	check(not remote.OnServerInvoke(player, forged, forged.Position), "Remote rejects forged markers")
	tool.Enabled = false
	check(not remote.OnServerInvoke(player, marker, marker.Position), "A disabled tool cannot unweld")
	tool.Enabled = true
	local deferred = weld.RegisterUnweldValidator(function() coroutine.yield(); return true end)
	unwelding = coroutine.create(function() result = {remote.OnServerInvoke(player, marker, marker.Position)} end)
	check(coroutine.resume(unwelding), "Remote conditions can yield")
	tool.Parent = nil
	check(coroutine.resume(unwelding) and not result[1] and result[2] == "EquipTool" and weld.HasWeld(b, c),
		"Unequipping during validation cancels the remote operation")
	deferred(); tool.Parent = player.Character
	check(remote.OnServerInvoke(player, marker, marker.Position) and not weld.HasWeld(b, c), "Equipped unweld tool removes the clicked weld")
	check(not remote.OnServerInvoke(player, marker, marker.Position), "Repeated use of a removed marker cannot affect another edge")

	local farA, farB = target("ServerA", 100, true), target("ServerB", 102.5, true)
	check(not weld.Weld(farA, farB, player.UserId) and weld.Weld(farA, farB), "Optional actor controls reach for server-created welds")
	local actorWasNil = false
	local remove = weld.RegisterUnweldValidator(function(_, _, id) actorWasNil = id == nil; return true end)
	check(weld.Unweld(farB, farA) and actorWasNil and not weld.HasWeld(farA, farB), "Server unweld is symmetric and still invokes conditions with nil actor")
	remove()
	local t0, t1, t2 = target("Cycle0", 50, true), target("Cycle1", 51, true), target("Cycle2", 52, true)
	check(weld.Weld(t0, t1) and weld.Weld(t1, t2) and weld.Weld(t0, t2), "API supports cyclic welded groups")
	check(weld.Unweld(t0, t2) and not weld.HasWeld(t0, t2) and #weld.GetConnectedTargets(t0) == 2
		and table.find(weld.GetIndirectConnections(t0), t2), "Removing an edge preserves alternate paths")

	-- Clicked marker location is independent of the closest physical connection.
	local model = mock.Instance.new("Model"); model.Name,model.Parent = "MarkerModel",mock.workspace
	collection:AddTag(model,"can-weld")
	local clicked = mock.part("ClickedFace",0,model)
	local closest = mock.part("ClosestMount",3,model)
	local neighbor = target("MarkerNeighbor",5.5,true)
	for _, part in {clicked,closest,neighbor} do part.CFrame = mock.CFrame.new(part.Position+mock.Vector3.new(0,0,10)) end
	local offset = mock.Vector3.new(-1,0.6,0.4)
	local weldTool = mock.Instance.new("Tool"); weldTool.Name,weldTool.Parent = "WeldTool",player.Character
	local weldRemote = mock.services.ReplicatedStorage.WeldNearest
	check(weldRemote.OnServerInvoke(player,clicked,clicked.CFrame:PointToWorldSpace(offset)),"Tool passes the clicked point through nearest-target welding")
	local selectedMarker = markerFor(model,neighbor)
	check((selectedMarker.Position-clicked.CFrame:PointToWorldSpace(offset)).Magnitude < 0.0001,
		"Marker stays at the off-center click even when another child is closest to the neighbor")
	check(selectedMarker.Parent.ObjectWeld.Part0 == closest and selectedMarker.Parent.MarkerWeld.Part0 == clicked,
		"Physical weld uses closest parts while the marker follows the clicked part")
	check(weld.UnweldMarker(selectedMarker,player.UserId),"The visible clicked-point marker can be removed normally")
	-- Move and rotate the model while a custom condition yields.
	local waiting = weld.RegisterWeldValidator(function() coroutine.yield(); return true end)
	local response
	local pendingWeld = coroutine.create(function()
		response = {weldRemote.OnServerInvoke(player,clicked,clicked.CFrame:PointToWorldSpace(offset))}
	end)
	check(coroutine.resume(pendingWeld),"Clicked-point weld can wait for a server condition")
	local transform = mock.CFrame.new(0,0,5)*mock.CFrame.fromAxisAngle(mock.Vector3.yAxis,math.pi*0.5)
	for _, part in {clicked,closest,neighbor} do part.CFrame = transform*part.CFrame end
	check(coroutine.resume(pendingWeld) and response[1],"Moved clicked point is checked in its current world position")
	selectedMarker = markerFor(model,neighbor)
	check((selectedMarker.Position-clicked.CFrame:PointToWorldSpace(offset)).Magnitude < 0.0001,
		"Movement and rotation during validation preserve the local clicked point")
	waiting(); weld.Unweld(model,neighbor)
	check(not weldRemote.OnServerInvoke(player,clicked,closest.Position),"A point on another child cannot be passed as the clicked part's point")
	local invalidSelection = {part=neighbor,point=mock.Vector3.zero}
	check(not weld.Weld(model,neighbor,player.UserId,nil,invalidSelection),"Marker selection must belong to the first target")
	check(weld.Weld(model,neighbor),"Existing server API still welds without a selected marker point")
	weld.Unweld(model,neighbor); model:Destroy(); neighbor:Destroy(); weldTool:Destroy()
	print("Weld extensions: " .. checks .. " checks passed")
end
