return function(mock, modules, startClient)
	local checks = 0
	local function check(value,message) assert(value,message); checks += 1 end
	local player = mock.player(1901)
	mock.services.Players.LocalPlayer = player
	local gui = mock.Instance.new("PlayerGui"); gui.Name,gui.Parent = "PlayerGui",player
	local tool = mock.Instance.new("Tool"); tool.Name,tool.Parent = modules.HingeConfig.TOOL_NAME,player.Character
	local client = mock.Instance.new("LocalScript"); client.Name,client.Parent = "Client",tool
	local a,b = mock.part("ClientHingeA",3),mock.part("ClientHingeB",6.5)
	local x = mock.Vector3.new(1,0,0)
	for _, part in {a,b} do
		mock.services.CollectionService:AddTag(part,"can-weld")
		mock.services.CollectionService:AddTag(part,"can-drag")
	end
	local click,cancel,status = mock.services.ReplicatedStorage.HingeToolClick,
		mock.services.ReplicatedStorage.CancelHingeTool,mock.services.ReplicatedStorage.HingeToolStatus
	local lastPayload
	local finishBeforeReply = false
	click.InvokeServer = function(_,hit,point,normal)
		local allowed,reason,payload = click.OnServerInvoke(player,hit,point,normal)
		lastPayload = payload
		if finishBeforeReply and allowed and reason == "Pulling" then
			b.CFrame = mock.CFrame.new(5,0,0)
			mock.clock += 0.05; modules.HingeServer.Step()
			mock.clock += modules.HingeConfig.SETTLE_TIME+0.01; modules.HingeServer.Step()
			local event = status.lastClientEvent
			status.OnClientEvent:Fire(event[2],event[3])
		end
		return allowed,reason,payload
	end
	cancel.FireServer = function() cancel.OnServerEvent:Fire(player) end
	local hovered,point,normal
	mock.raycastQuery = function(_,direction)
		return if direction.Magnitude > 900 and hovered then {Instance=hovered,Position=point,Normal=normal} else nil
	end
	local function activate(part,side)
		hovered,point,normal = part,part.Position+x*side,x*side
		mock.clock += 1; tool.Activated:Fire()
		mock.services.RunService.RenderStepped:Fire()
	end
	local function markers()
		local result = {}
		for _, child in mock.workspace:GetChildren() do if child.Name == "HingeSelectionPoint" then table.insert(result,child) end end
		return result
	end
	local function q(processed)
		mock.services.UserInputService.InputBegan:Fire({KeyCode=modules.HingeConfig.CANCEL_KEY},processed or false)
	end
	startClient(tool)
	tool.Equipped:Fire()
	activate(a,1)
	check(#markers() == 1 and markers()[1].CFrame.Position.X == 4,"The first chosen point appears on its actual surface")
	check(not markers()[1].CanQuery and not markers()[1].CanCollide,"Selection markers cannot block clicks or physics")
	local selectedId = lastPayload.id
	activate(b,-1)
	check(#markers() == 2 and modules.InteractionLocks:IsLocked(a),"The second click starts attraction and displays both points")
	check(a.HingePullPosition ~= nil,"Client forwards the ray hit normal to the validated server flow")
	mock.services.UserInputService.focused = mock.Instance.new("TextBox")
	q(); check(modules.InteractionLocks:IsLocked(a),"Typing Q in a text field does not cancel attraction")
	mock.services.UserInputService.focused = nil
	q(true); check(modules.InteractionLocks:IsLocked(a),"Already processed input is ignored")
	q(); check(not modules.InteractionLocks:IsLocked(a) and #markers() == 0,"Q cancels server attraction and removes local points")
	activate(a,1)
	local freshId = lastPayload.id
	status.OnClientEvent:Fire(selectedId,"Cancelled")
	check(#markers() == 1 and freshId > selectedId,"Old server messages cannot erase a newer selection")
	tool.Unequipped:Fire()
	check(#markers() == 0 and not gui.HingeToolHint.Enabled,"Unequipping clears selection and hides the tool UI")
	tool.Equipped:Fire(); activate(a,1); activate(b,-1)
	b.CFrame = mock.CFrame.new(5,0,0)
	mock.clock += 0.05; modules.HingeServer.Step()
	mock.clock += modules.HingeConfig.SETTLE_TIME+0.01; modules.HingeServer.Step()
	local event = status.lastClientEvent
	check(event[1] == player and event[3] == "Mounted","The server reports successful welding to the owning player")
	status.OnClientEvent:Fire(event[2],event[3])
	check(#markers() == 0 and gui.HingeToolHint:FindFirstChildWhichIsA("TextLabel").Text == "Объекты сварены",
		"Success clears selection markers and displays the permanent connection result")
	modules.WeldServer.Unweld(a,b); b.CFrame = mock.CFrame.new(6.5,0,0)
	finishBeforeReply = true
	activate(a,1); activate(b,-1)
	check(#markers() == 0 and gui.HingeToolHint:FindFirstChildWhichIsA("TextLabel").Text == "Объекты сварены",
		"A delayed start reply cannot resurrect markers after the terminal event")
	tool:Destroy()
	check(not gui:FindFirstChild("HingeToolHint") and mock.services.UserInputService.InputBegan:ListenerCount() == 0,
		"Destroying the tool disconnects keyboard and status listeners")
	check(modules.WeldServer.HasWeld(a,b) and not modules.WeldServer.HasHinge(a,b),"Tool cleanup does not delete an already completed weld")
	modules.WeldServer.Unweld(a,b)
	mock.raycastQuery = nil
	print("Hinge client: " .. checks .. " checks passed (mocked two-click input and status delivery)")
end
