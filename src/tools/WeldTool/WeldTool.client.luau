local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local config = require(ReplicatedStorage.Shared.WeldConfig)
local ObjectTargets = require(ReplicatedStorage.Shared.ObjectTargets)
local remote = ReplicatedStorage:WaitForChild("WeldNearest") :: RemoteFunction
local player = Players.LocalPlayer
local tool = script.Parent :: Tool
local mouse = player:GetMouse()
local equipped, pending = false, false
local statusUntil = 0
local hint = "Наведите на объект и нажмите: сварка с ближайшим объектом"
local messages = {
	Welded = "Объекты сварены",
	InvalidTarget = "Выберите модель или деталь с тегом can-weld",
	NoNearbyTarget = "Рядом нет другого подходящего объекта",
	TooFar = "Объекты слишком далеко друг от друга",
	OutOfReach = "Подойдите ближе",
	AlreadyWelded = "Эти объекты уже сварены",
	Busy = "Объект сейчас занят — попробуйте ещё раз",
	Denied = "Сварка запрещена серверной проверкой",
	EquipTool = "Возьмите инструмент сварки",
	Failed = "Сварка не выполнена",
}

local highlight = Instance.new("Highlight")
highlight.Name = "WeldHoverHighlight"
highlight.FillColor, highlight.OutlineColor = config.MARKER_COLOR, config.MARKER_COLOR
highlight.FillTransparency = 0.85
highlight.DepthMode, highlight.Enabled = Enum.HighlightDepthMode.Occluded, false
highlight.Parent = workspace
local gui = Instance.new("ScreenGui")
gui.Name, gui.ResetOnSpawn, gui.Enabled = "WeldToolHint", true, false
local label = Instance.new("TextLabel")
label.AnchorPoint = Vector2.new(0.5, 1)
label.Position, label.Size = UDim2.new(0.5, 0, 1, -80), UDim2.new(0.8, 0, 0, 48)
label.BackgroundColor3, label.BackgroundTransparency = Color3.fromRGB(25, 25, 30), 0.2
label.TextColor3 = Color3.new(1, 1, 1)
label.TextSize, label.TextWrapped, label.Font = 18, true, Enum.Font.Gotham
label.Text, label.Parent = hint, gui
gui.Parent = player:WaitForChild("PlayerGui")

local connections = {}
table.insert(connections, tool.Equipped:Connect(function()
	equipped, gui.Enabled = true, true
end))
table.insert(connections, tool.Unequipped:Connect(function()
	equipped, gui.Enabled, highlight.Enabled = false, false, false
end))
table.insert(connections, RunService.RenderStepped:Connect(function()
	if not equipped then return end
	local target = ObjectTargets.findTagged(mouse.Target, config.TAG_NAME)
	highlight.Adornee, highlight.Enabled = target, target ~= nil
	if os.clock() >= statusUntil and not pending then label.Text = hint end
end))
table.insert(connections, tool.Activated:Connect(function()
	if not equipped or pending then return end
	pending = true
	label.Text = "Проверка сварки…"
	local ok, _, reason = pcall(function() return remote:InvokeServer(mouse.Target, mouse.Hit.Position) end)
	pending = false
	label.Text = messages[if ok then reason else "Failed"] or messages.Failed
	statusUntil = os.clock() + 2
end))
script.Destroying:Connect(function()
	for _, connection in connections do connection:Disconnect() end
	highlight:Destroy()
	gui:Destroy()
end)
