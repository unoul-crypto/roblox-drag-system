return function(mock, modules)
	local checks = 0
	local function check(value,message) assert(value,message); checks += 1 end
	local collection, weld, selection = mock.services.CollectionService,modules.WeldServer,modules.ConnectionSelection
	local folder = mock.workspace.WeldConnections
	local player = mock.player(2001)
	mock.services.Players.LocalPlayer = player
	local playerGui = mock.Instance.new("PlayerGui"); playerGui.Name,playerGui.Parent = "PlayerGui",player
	local camera = mock.workspace.CurrentCamera
	camera.ViewportSize = {X=1280,Y=720}
	local onScreen = true
	camera.WorldToViewportPoint = function(_,point) return mock.Vector3.new(400,300,10),onScreen end
	local mouse = {X=100,Y=100}
	mock.services.UserInputService.GetMouseLocation = function() return mouse end
	local a = mock.Instance.new("Model"); a.Name,a.Parent = "UnweldA",mock.workspace
	local part = mock.part("AChild",0,a); part.CFrame = mock.CFrame.new(0,0,10)
	local b,c = mock.part("UnweldB",2.5),mock.part("UnweldC",5)
	local d = mock.part("UnweldD",-2.5)
	for _, child in {b,c,d} do child.CFrame = mock.CFrame.new(child.Position.X,0,10) end
	for _, target in {a,b,c,d} do collection:AddTag(target,"can-weld") end
	check(weld.Weld(a,b) and weld.Weld(b,c) and weld.Weld(a,d),"Fixture includes two direct and one indirect connection")
	local direct = selection.records(folder,a)
	check(#direct == 2,"Only the selected model's direct connections are listed")
	for _, link in direct do check(link.a ~= c and link.b ~= c,"Indirect neighbors never become selectable links") end
	check(selection.findTarget(part,selection.records(folder)) == a,"Clicking a child resolves the actual model endpoint")
	collection:RemoveTag(a,"can-weld")
	check(selection.findTarget(part,selection.records(folder)) == a,"Removing can-weld does not prevent selecting old connections")
	local partial = mock.Instance.new("Folder"); partial.Parent = folder
	check(not selection.read(partial),"Partially replicated records are skipped")
	partial:Destroy()
	local packed = selection.layout({{x=400,y=300,link=direct[1]},{x=400,y=300,link=direct[2]}},1280,720,36,6)
	check(#packed == 2 and (math.abs(packed[1].x-packed[2].x) >= 42 or math.abs(packed[1].y-packed[2].y) >= 42),
		"Coincident projected points receive separately clickable icons")
	local corner = selection.layout({{x=0,y=0},{x=0,y=0},{x=0,y=0},{x=0,y=0}},200,200,36,6)
	check(#corner == 4,"Overlapping icons at a viewport corner remain accessible")
	for i, item in corner do
		check(item.x >= 18 and item.y >= 18 and item.x <= 182 and item.y <= 182,"Layout stays inside the viewport")
		for j = 1,i-1 do check(math.abs(item.x-corner[j].x) >= 42 or math.abs(item.y-corner[j].y) >= 42,"Corner icons do not overlap") end
	end
	check(#selection.layout({{x=0,y=0}},10,10,36,6) == 0,"A viewport smaller than an icon is handled safely")
	local tool = mock.Instance.new("Tool"); tool.Name,tool.Parent = "UnweldTool",player.Character
	local client = mock.Instance.new("LocalScript"); client.Name,client.Parent = "Client",tool
	local remote = mock.services.ReplicatedStorage.UnweldMarker
	local previousInvoke, requests = remote.InvokeServer,0
	local waitForReply = false
	remote.InvokeServer = function(_,hit,point)
		requests += 1
		if waitForReply then coroutine.yield() end
		return remote.OnServerInvoke(player,hit,point)
	end
	local hovered, obstacle = part,nil
	mock.raycastQuery = function(_,direction,params)
		if direction.Magnitude > 900 then return if hovered then {Instance=hovered,Position=hovered.Position} else nil end
		-- Hidden inside both participating objects: the existing server query excludes them.
		local ignored = params.FilterDescendantsInstances
		check(table.find(ignored,player.Character) ~= nil,"Server visibility checks retain the character exclusion")
		return obstacle
	end
	modules.ConnectionToolClient(tool,client,true)
	local function frame(dt)
		mock.clock += dt or 0.2; mock.services.RunService.RenderStepped:Fire()
	end
	local function buttons()
		local result = {}
		for _, child in playerGui.UnweldConnections:GetChildren() do if child:IsA("TextButton") then table.insert(result,child) end end
		return result
	end
	local overlay = playerGui.UnweldConnections
	check(overlay.IgnoreGuiInset and not overlay.Enabled,"Overlay starts hidden and uses viewport coordinates")
	tool.Equipped:Fire(); frame(); tool.Activated:Fire(); frame()
	check(#buttons() == 2 and requests == 0,"A model click displays direct icons without a server mutation request")
	hovered = b; tool.Activated:Fire(); frame()
	check(#buttons() == 2 and requests == 0,"Clicking a different endpoint switches its direct-connection selection")
	hovered = nil; tool.Activated:Fire(); frame()
	check(#buttons() == 0,"Clicking empty space clears the icon selection")
	hovered = part; tool.Activated:Fire(); frame()
	local button = buttons()[1]
	mouse = {X=button.Position[2],Y=button.Position[4]}; frame()
	local h0,h1 = mock.workspace.UnweldPair1,mock.workspace.UnweldPair2
	check(h0.Enabled and h1.Enabled and h0.DepthMode == mock.Enum.HighlightDepthMode.AlwaysOnTop,
		"Hovering an icon highlights both endpoints over occluding geometry")
	check((h0.Adornee == a or h1.Adornee == a) and h0.Adornee ~= h1.Adornee,"Pair highlighting includes the selected model and its direct neighbor")
	check(not mock.workspace.UnweldToolHoverHighlight.Enabled,"World hover does not compete with the icon's pair highlight")
	tool.Activated:Fire()
	check(requests == 0 and #buttons() == 2,"A world activation over an icon cannot remove or reselect another connection")
	button.Activated:Fire(); frame()
	check(requests == 1 and #buttons() == 1 and #weld.GetDirectConnections(a) == 1,"Clicking an icon deletes exactly its server-validated connection")
	local remaining = selection.records(folder,a)[1]
	local reject = weld.RegisterUnweldValidator(function() return false end)
	buttons()[1].Activated:Fire(); frame()
	check(#buttons() == 1 and weld.HasWeld(remaining.a,remaining.b),"Custom server conditions also protect icon deletion")
	reject()
	obstacle = {}; buttons()[1].Activated:Fire(); frame()
	check(#buttons() == 1 and weld.HasWeld(remaining.a,remaining.b),"Icons cannot bypass a third-party obstacle in the server visibility check")
	obstacle = nil
	local root = player.Character.HumanoidRootPart
	root.CFrame = mock.CFrame.new(100,0,0); frame()
	check(#buttons() == 0,"Out-of-reach connections lose their interactive icons")
	root.CFrame = mock.CFrame.new(); frame()
	check(#buttons() == 1,"Icons return after approaching the selected model")
	onScreen = false; frame(); check(#buttons() == 0,"Offscreen connections hide their icons")
	onScreen = true; frame()
	-- Keep the ordinary marker-click path: move the pointer away from all icons.
	mouse = {X=100,Y=100}; hovered = remaining.marker
	tool.Activated:Fire(); frame()
	check(#selection.records(folder,a) == 0 and #buttons() == 0,"An ordinary world click on a marker still deletes the connection")
	-- Selection stays live when server scripts add/remove a direct connection.
	collection:AddTag(a,"can-weld")
	check(weld.Weld(a,d),"A server script can add another direct connection")
	frame(); check(#buttons() == 1,"The selected model's icons include newly replicated connections")
	remaining = selection.records(folder,a)[1]
	weld.RemoveWeld(a,d); frame()
	check(#buttons() == 0 and not h0.Enabled and not h1.Enabled,"External removal clears stale icons and pair highlights")
	check(weld.Weld(a,d),"Recreate a link before delayed deletion")
	frame(); waitForReply = true
	local currentButton = buttons()[1]
	local before = requests
	local pending = coroutine.create(function() currentButton.Activated:Fire() end)
	check(coroutine.resume(pending),"A remote reply may be delayed")
	currentButton.Activated:Fire()
	check(requests == before+1,"Repeated icon clicks share the existing one-pending-request guard")
	tool.Unequipped:Fire()
	tool.Parent = nil
	check(#buttons() == 0 and not overlay.Enabled and not h0.Enabled,"Unequipping clears icons and highlights")
	check(coroutine.resume(pending) and weld.HasWeld(a,d),"Unequipping while waiting prevents late server removal")
	check(#buttons() == 0,"A delayed reply cannot revive the cleared selection")
	waitForReply = false; tool.Parent = player.Character; tool.Equipped:Fire(); hovered = part; mouse = {X=100,Y=100}
	frame(); tool.Activated:Fire(); frame()
	check(#buttons() == 1,"Re-equipping permits a fresh selection")
	player.Character:FindFirstChildWhichIsA("Humanoid").Health = 0; frame()
	check(#buttons() == 0 and not overlay.Enabled,"Death clears the connection overlay")
	tool:Destroy()
	check(not overlay.Parent and not h0.Parent and not h1.Parent and tool.Activated:ListenerCount() == 0,
		"Destruction disconnects input and releases all overlay objects")
	remote.InvokeServer = previousInvoke; mock.raycastQuery = nil
	a:Destroy(); b:Destroy(); c:Destroy(); d:Destroy()
	print("Unweld selection: "..checks.." checks passed (mocked replication, UI, input and server guards)")
end
