local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local shared = ReplicatedStorage.Shared
local config = require(shared.HingeConfig)
local ObjectTargets = require(shared.ObjectTargets)
local ObjectToolClient = require(shared.ObjectToolClient)
local tool = script.Parent
local cancelRemote = ReplicatedStorage:WaitForChild("CancelHingeTool")
local statusRemote = ReplicatedStorage:WaitForChild("HingeToolStatus")
local phase, currentId, selection = "Idle",0,nil
local terminalId, terminalReason = 0,"Cancelled"
local markers, connections = {},{}

local function clear()
	phase, selection = "Idle",nil
	for _, marker in markers do marker:Destroy() end
	table.clear(markers)
end

local function cancel()
	clear()
	cancelRemote:FireServer()
end

local function showPoints(payload)
	for _, marker in markers do marker:Destroy() end
	table.clear(markers)
	selection = payload
	for _ = 1, if payload.part1 then 2 else 1 do
		local marker = Instance.new("Part")
		marker.Name, marker.Shape, marker.Size = "HingeSelectionPoint",Enum.PartType.Ball,Vector3.one*config.MARKER_SIZE
		marker.Color, marker.Material = config.MARKER_COLOR,Enum.Material.Neon
		marker.Anchored, marker.CanCollide, marker.CanQuery, marker.CanTouch = true,false,false,false
		marker.Parent = workspace
		table.insert(markers,marker)
	end
end

local hint = "Нажмите на первую точку, затем на вторую. Q — отмена"
local ui
ui = ObjectToolClient(tool,script,{
	remoteName="HingeToolClick", hint=hint, sendNormal=true, color=config.MARKER_COLOR,
	ignoreFolders={"WeldConnections"},
	getHint=function()
		return if phase == "Selected" then "Первая точка выбрана. Нажмите вторую точку. Q — отмена"
			elseif phase == "Pulling" then "Притягивание… Q — отменить" else hint
	end,
	messages={Selected="Первая точка выбрана",Pulling="Притягивание…",Mounted="Объекты сварены",
		TooWeak="Точки не сошлись: подведите детали ближе или используйте домкрат",TooFar="Для этой мощности точки слишком далеко",
		BothFixed="Оба объекта закреплены",Disabled="Притягивание отключено в настройках",SameTarget="Выберите другую модель",
		AlreadyConnected="Объекты уже соединены",Busy="Объект занят — отпустите его и повторите",
		InvalidTarget="Выберите поверхность объекта с can-weld",NotAlive="Персонаж должен быть жив",EquipTool="Возьмите инструмент притягивания",
		OutOfReach="Подойдите ближе",NotVisible="Точка скрыта препятствием",Changed="Состав или опора модели изменились",
		Denied="Действие запрещено серверной проверкой",Cancelled="Притягивание отменено",MovedTooFar="Превышено допустимое перемещение",
		NotReady="Точки ещё не совпадают",Failed="Не удалось соединить модели"},
	hoverTarget=function(hit) return ObjectTargets.findTagged(hit,config.TAG_NAME) end,
	onResult=function(ok,allowed,reason,payload)
		if not ok or not payload or payload.id < currentId then return end
		-- The terminal RemoteEvent can arrive before a delayed RemoteFunction reply.
		if payload.id <= terminalId then ui.ShowStatus(terminalReason); return end
		currentId = payload.id
		if allowed and (reason == "Selected" or reason == "Pulling") then phase=reason; showPoints(payload)
		else clear() end
	end,
})
table.insert(connections,statusRemote.OnClientEvent:Connect(function(id,reason)
	if type(id) ~= "number" or id < currentId then return end
	currentId, terminalId, terminalReason = id,id,reason
	clear(); ui.ShowStatus(reason)
end))
table.insert(connections,RunService.RenderStepped:Connect(function()
	if not selection then return end
	for index, marker in markers do
		local part = if index == 1 then selection.part else selection.part1
		local point = if index == 1 then selection.point else selection.point1
		if part and part.Parent then marker.CFrame=CFrame.new(part.CFrame:PointToWorldSpace(point)) end
	end
end))
table.insert(connections,UserInputService.InputBegan:Connect(function(input,processed)
	if not processed and tool.Parent == Players.LocalPlayer.Character and input.KeyCode == config.CANCEL_KEY
		and not UserInputService:GetFocusedTextBox() then cancel() end
end))
table.insert(connections,tool.Unequipped:Connect(cancel))
script.Destroying:Connect(function()
	cancel()
	for _, connection in connections do connection:Disconnect() end
end)
