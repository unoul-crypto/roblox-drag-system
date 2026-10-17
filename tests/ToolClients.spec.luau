return function(mock, modules, startJackTool)
	local checks = 0
	local function check(value, message) assert(value, message); checks += 1 end
	local player = mock.player(1601)
	mock.services.Players.LocalPlayer = player
	local gui = mock.Instance.new("PlayerGui"); gui.Name, gui.Parent = "PlayerGui", player
	local camera = mock.Instance.new("Camera")
	camera.ViewportSize = {X=1280,Y=720}
	camera.ViewportPointToRay = function() return {Origin = mock.Vector3.zero, Direction = mock.Vector3.new(0,0,-1)} end
	mock.workspace.CurrentCamera = camera
	mock.services.UserInputService.GetMouseLocation = function() return {X = 100, Y = 100} end
	local hovered, calls
	mock.raycastQuery = function() return if hovered then {Instance = hovered, Position = hovered.Position} else nil end
	local target = mock.part("ToolTarget", 5)
	mock.services.CollectionService:AddTag(target, "can-weld")
	mock.services.CollectionService:AddTag(target, "can-drag")
	local marker = mock.part("ToolMarker", 6)
	marker:SetAttribute(modules.WeldConfig.MARKER_ATTRIBUTE, true)
	for _, setup in {
		{name = "WeldTool", remote = "WeldNearest", result = "Welded", target = target},
		{name = "UnweldTool", remote = "UnweldMarker", result = "Unwelded", target = marker},
		{name = "JackTool", remote = "PlaceJack", result = "Placed", target = target},
	} do
		local tool = mock.Instance.new("Tool"); tool.Name, tool.Parent = setup.name, player.Character
		local client = mock.Instance.new("LocalScript"); client.Name, client.Parent = "Client", tool
		local remote = mock.services.ReplicatedStorage:FindFirstChild(setup.remote)
		local previous = remote.InvokeServer
		remote.InvokeServer = function(_, hit, point) calls = {hit, point}; return true, setup.result end
		if setup.name == "JackTool" then startJackTool(tool)
		else modules.ConnectionToolClient(tool, client, setup.name == "UnweldTool") end
		local hint = gui:FindFirstChild(setup.name .. "Hint")
		local highlight = mock.workspace:FindFirstChild(setup.name .. "HoverHighlight")
		check(hint and not hint.Enabled and not highlight.Enabled, "Tool UI starts hidden")
		tool.Equipped:Fire(); hovered = setup.target
		mock.services.RunService.RenderStepped:Fire()
		check(hint.Enabled and highlight.Enabled and highlight.Adornee == setup.target, "Equipped tool highlights its supported target")
		local excluded = mock.lastRaycast.params.FilterDescendantsInstances
		check(table.find(excluded, player.Character), "Ray selection ignores the player's own character")
		check((table.find(excluded, mock.workspace.WeldConnections) ~= nil) == (setup.name ~= "UnweldTool"),
			"Only the unweld tool targets weld markers")
		calls = nil; tool.Activated:Fire()
		check(calls and calls[1] == setup.target and calls[2] == setup.target.Position, "Tool sends only the hit instance and point")
		check(hint:FindFirstChildWhichIsA("TextLabel").Text ~= "Проверка…", "Server results replace the pending message")
		if setup.name == "JackTool" then
			local jack = mock.Instance.new("Model"); jack.Parent = mock.workspace
			jack:SetAttribute(modules.JackConfig.MODEL_ATTRIBUTE, true)
			local foot = mock.part("JackFoot", 4, jack); hovered = foot
			mock.services.RunService.RenderStepped:Fire()
			check(highlight.Adornee == jack, "Jack selection highlights the whole existing support")
			tool.Activated:Fire()
			check(calls[1] == foot, "Clicking an existing jack sends its actual hit part for removal")
			jack:Destroy()
		end
		tool.Unequipped:Fire()
		check(not hint.Enabled and not highlight.Enabled, "Unequipping hides tool UI")
		calls = nil; tool.Activated:Fire()
		check(calls == nil, "An unequipped tool cannot send requests")
		tool:Destroy()
		check(not hint.Parent and not highlight.Parent and tool.Activated:ListenerCount() == 0,
			"Destroying a tool cleans up hints, highlights and event connections")
		remote.InvokeServer = previous
	end
	mock.raycastQuery = nil
	print("Tool clients: " .. checks .. " checks passed (mocked input and UI)")
end
