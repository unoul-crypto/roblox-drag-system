-- Shared presentation and input; permissions and graph changes live on the server.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local config = require(script.Parent.WeldConfig)
local ObjectTargets = require(script.Parent.ObjectTargets)

local messages = {
	Welded = "Объекты сварены", Unwelded = "Соединение удалено",
	InvalidTarget = "Выберите объект с тегом can-weld",
	InvalidMarker = "Выберите шарик сварки", NotWelded = "Соединение уже удалено",
	NoNearbyTarget = "Рядом нет подходящего объекта", TooFar = "Объекты слишком далеко",
	OutOfReach = "Подойдите ближе", AlreadyWelded = "Эти объекты уже сварены",
	Busy = "Объект занят — отпустите его и повторите",
	Denied = "Действие запрещено серверной проверкой", EquipTool = "Возьмите нужный инструмент",
	Failed = "Действие не выполнено",
	NotAlive = "Персонаж должен быть жив", NotVisible = "Объект скрыт препятствием",
}

return function(tool: Tool, ownerScript: LocalScript, unweld: boolean)
	local player = Players.LocalPlayer
	local remote = ReplicatedStorage:WaitForChild(if unweld then "UnweldMarker" else "WeldNearest") :: RemoteFunction
	local equipped, pending, destroyed = false, false, false
	local statusUntil = 0
	local hint = if unweld then "Нажмите на шарик сварки, чтобы удалить соединение"
		else "Нажмите на объект: сварка с ближайшим объектом"

	local function pick(): RaycastResult?
		local camera = workspace.CurrentCamera
		if not camera then return nil end
		local excluded = {}
		if player.Character then table.insert(excluded, player.Character) end
		local folder = workspace:FindFirstChild("WeldConnections")
		if not unweld and folder then table.insert(excluded, folder) end
		local parameters = RaycastParams.new()
		parameters.FilterType, parameters.FilterDescendantsInstances = Enum.RaycastFilterType.Exclude, excluded
		local position = UserInputService:GetMouseLocation()
		local ray = camera:ViewportPointToRay(position.X, position.Y)
		return workspace:Raycast(ray.Origin, ray.Direction * 1000, parameters)
	end

	local function hoverTarget(hit: Instance?): Instance?
		if unweld then
			return if hit and hit:GetAttribute(config.MARKER_ATTRIBUTE) == true then hit else nil
		end
		return ObjectTargets.findTagged(hit, config.TAG_NAME)
	end
	local highlight = Instance.new("Highlight")
	highlight.Name = "ConnectionHoverHighlight"
	highlight.FillColor, highlight.OutlineColor = config.MARKER_COLOR, config.MARKER_COLOR
	highlight.FillTransparency = 0.85
	highlight.DepthMode, highlight.Enabled = Enum.HighlightDepthMode.Occluded, false
	highlight.Parent = workspace
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.Enabled = "ConnectionToolHint", true, false
	local label = Instance.new("TextLabel")
	label.AnchorPoint = Vector2.new(0.5, 1)
	label.Position, label.Size = UDim2.new(0.5, 0, 1, -80), UDim2.new(0.8, 0, 0, 48)
	label.BackgroundColor3, label.BackgroundTransparency = Color3.fromRGB(25, 25, 30), 0.2
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextSize, label.TextWrapped, label.Font = 18, true, Enum.Font.Gotham
	label.Text, label.Parent = hint, gui
	gui.Parent = player:WaitForChild("PlayerGui")

	local connections = {}
	table.insert(connections, tool.Equipped:Connect(function() equipped, gui.Enabled = true, true end))
	table.insert(connections, tool.Unequipped:Connect(function()
		equipped, gui.Enabled, highlight.Enabled = false, false, false
	end))
	table.insert(connections, RunService.RenderStepped:Connect(function()
		if not equipped then return end
		local result = pick()
		local target = hoverTarget(if result then result.Instance else nil)
		highlight.Adornee, highlight.Enabled = target, target ~= nil
		if os.clock() >= statusUntil and not pending then label.Text = hint end
	end))
	table.insert(connections, tool.Activated:Connect(function()
		if not equipped or pending then return end
		local result = pick()
		if not result then return end
		pending = true
		label.Text = "Проверка…"
		local ok, _, reason = pcall(function() return remote:InvokeServer(result.Instance, result.Position) end)
		pending = false
		if destroyed then return end
		label.Text = messages[if ok then reason else "Failed"] or messages.Failed
		statusUntil = os.clock() + 2
	end))
	ownerScript.Destroying:Connect(function()
		destroyed = true
		for _, connection in connections do connection:Disconnect() end
		highlight:Destroy()
		gui:Destroy()
	end)
end
