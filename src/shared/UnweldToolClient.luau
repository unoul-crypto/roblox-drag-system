local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local config = require(script.Parent.WeldConfig)
local ObjectTargets = require(script.Parent.ObjectTargets)
local InteractionCharacter = require(script.Parent.InteractionCharacter)
local Selection = require(script.Parent.ConnectionSelection)
local ObjectToolClient = require(script.Parent.ObjectToolClient)

return function(tool: Tool, ownerScript: LocalScript, messages)
	local player = Players.LocalPlayer
	local equipped, destroyed, selected = false,false,nil
	local links, icons, placements, connections = {},{},{},{}
	local nextRefresh, selectedAt = 0,0
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.IgnoreGuiInset = "UnweldConnections",true,true
	gui.DisplayOrder, gui.Enabled, gui.Parent = 30,false,player:WaitForChild("PlayerGui")
	local highlights = {}
	for index = 1,2 do
		local highlight = Instance.new("Highlight")
		highlight.Name = "UnweldPair"..index
		highlight.FillColor, highlight.OutlineColor = config.MARKER_COLOR,config.MARKER_COLOR
		highlight.FillTransparency, highlight.DepthMode = 0.7,Enum.HighlightDepthMode.AlwaysOnTop
		highlight.Enabled, highlight.Parent = false,workspace
		table.insert(highlights,highlight)
	end
	local function clearHighlights()
		for _, highlight in highlights do highlight.Enabled,highlight.Adornee = false,nil end
	end
	local function destroyIcon(icon)
		icon.connection:Disconnect(); icon.button:Destroy(); icon.line:Destroy()
	end
	local function clear()
		selected, placements = nil,{}
		clearHighlights()
		for record, icon in icons do destroyIcon(icon); icons[record] = nil end
	end
	local function refresh()
		links = Selection.records(workspace:FindFirstChild("WeldConnections"))
		nextRefresh = os.clock()+config.UNWELD_REFRESH_INTERVAL
	end
	local function pointerLink()
		if not equipped or not gui.Enabled then return nil end
		local mouse, half = UserInputService:GetMouseLocation(),config.UNWELD_ICON_SIZE*0.5
		for _, item in placements do
			if math.abs(mouse.X-item.x) <= half and math.abs(mouse.Y-item.y) <= half then return item.link end
		end
		return nil
	end
	local ui
	local hints = table.clone(messages)
	hints.Selected = "Выберите значок соединения; при наведении подсвечиваются обе модели"
	hints.NoConnections = "У выбранной модели нет прямых соединений"
	ui = ObjectToolClient(tool,ownerScript,{
		remoteName="UnweldMarker", color=config.MARKER_COLOR, messages=hints,
		hint="Нажмите на модель для выбора соединения или на шарик сварки для удаления",
		getHint=function() return if selected then hints.Selected else "Нажмите на модель или шарик сварки" end,
		isPointerOverUI=function() return pointerLink() ~= nil end,
		hoverTarget=function(hit)
			if hit and hit:GetAttribute(config.MARKER_ATTRIBUTE) == true then return hit end
			return Selection.findTarget(hit,links)
		end,
		onActivate=function(result)
			if result and result.Instance:GetAttribute(config.MARKER_ATTRIBUTE) == true then return false end
			clear(); refresh()
			selected = if result then Selection.findTarget(result.Instance,links) else nil
			selectedAt = os.clock()
			ui.ShowStatus(if selected then "Selected" else "NoConnections")
			return true
		end,
		onResult=function() refresh() end,
	})
	local function createIcon(link,index)
		local button = Instance.new("TextButton")
		button.Name = "ConnectionIcon"
		button.AnchorPoint, button.Size = Vector2.new(0.5,0.5),UDim2.new(0,config.UNWELD_ICON_SIZE,0,config.UNWELD_ICON_SIZE)
		button.Text, button.TextSize, button.Font = "×"..index,18,Enum.Font.GothamBold
		button.TextColor3, button.BackgroundColor3 = Color3.new(0.08,0.08,0.1),link.marker.Color
		button.Active = true
		button.BorderSizePixel, button.ZIndex, button.Parent = 0,2,gui
		local line = Instance.new("Frame")
		line.Name, line.AnchorPoint = "ConnectionLine",Vector2.new(0.5,0.5)
		line.BackgroundColor3, line.BorderSizePixel, line.ZIndex, line.Active, line.Parent = link.marker.Color,0,1,false,gui
		local connection = button.Activated:Connect(function()
			if destroyed or not equipped or os.clock()-selectedAt < 0.1 then return end
			local current = Selection.read(link.record)
			if current and link.record.Parent == workspace:FindFirstChild("WeldConnections")
				and (current.a == selected or current.b == selected) then ui.Request(current.marker,current.marker.Position) end
		end)
		return {button=button,line=line,connection=connection}
	end
	table.insert(connections,tool.Equipped:Connect(function() equipped,gui.Enabled = true,true; refresh() end))
	table.insert(connections,tool.Unequipped:Connect(function() equipped,gui.Enabled = false,false; clear() end))
	table.insert(connections,player.CharacterRemoving:Connect(clear))
	table.insert(connections,RunService.RenderStepped:Connect(function()
		if not equipped then return end
		local root = InteractionCharacter.getRoot(player)
		if not root then clear(); gui.Enabled = false; return end
		gui.Enabled = true
		if os.clock() >= nextRefresh then refresh() end
		if selected and not ObjectTargets.isSupported(selected) then clear() end
		local camera, points, keep = workspace.CurrentCamera,{},{}
		for _, link in links do
			if not selected or (link.a ~= selected and link.b ~= selected) then continue end
			local current = Selection.read(link.record)
			if not current or not camera or link.record.Parent ~= workspace:FindFirstChild("WeldConnections") then continue end
			if (root.Position-current.marker.Position).Magnitude > config.MAX_USE_DISTANCE then continue end
			local point, onScreen = camera:WorldToViewportPoint(current.marker.Position)
			if not onScreen or point.Z <= 0 then continue end
			table.insert(points,{link=current,x=point.X,y=point.Y})
		end
		placements = if camera then Selection.layout(points,camera.ViewportSize.X,camera.ViewportSize.Y,config.UNWELD_ICON_SIZE,config.UNWELD_ICON_GAP) else {}
		for index, item in placements do
			local record = item.link.record
			local icon = icons[record] or createIcon(item.link,index)
			icons[record],keep[record] = icon,true
			icon.button.Text, icon.button.Position = "×"..index,UDim2.new(0,item.x,0,item.y)
			local dx, dy = item.x-item.anchorX,item.y-item.anchorY
			local length = math.sqrt(dx*dx+dy*dy)
			icon.line.Visible = length > config.UNWELD_ICON_SIZE*0.5
			icon.line.Position, icon.line.Size = UDim2.new(0,(item.x+item.anchorX)*0.5,0,(item.y+item.anchorY)*0.5),UDim2.new(0,length,0,2)
			icon.line.Rotation = math.deg(math.atan2(dy,dx))
		end
		for record, icon in icons do if not keep[record] then destroyIcon(icon); icons[record] = nil end end
		clearHighlights()
		local hovered = pointerLink()
		if hovered then
			for index, target in {hovered.a,hovered.b} do highlights[index].Adornee,highlights[index].Enabled = target,true end
		end
	end))
	ownerScript.Destroying:Connect(function()
		destroyed = true; clear()
		for _, connection in connections do connection:Disconnect() end
		for _, highlight in highlights do highlight:Destroy() end
		gui:Destroy()
	end)
end
