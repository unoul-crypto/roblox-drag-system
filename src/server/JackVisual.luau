-- Appearance and standard Roblox prompts; authority remains in JackServer.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local config = require(ReplicatedStorage.Shared.JackConfig)
local JackVisual = {}

local function part(name: string, size: Vector3, model: Model, color: Color3): BasePart
	local value = Instance.new("Part")
	value.Name, value.Size, value.Color = name, size, color
	value.Anchored, value.CanCollide, value.CanTouch = true, false, false
	value.TopSurface, value.BottomSurface = Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
	value.Material, value.Parent = Enum.Material.Metal, model
	return value
end

function JackVisual.Update(model: Model, base: Vector3, height: number, removing: boolean)
	model.Base.CFrame = CFrame.new(base + Vector3.new(0, 0.12, 0))
	local length = math.max(height - 0.24, 0.05)
	model.Column.Size = Vector3.new(0.35, length, 0.35)
	model.Column.CFrame = CFrame.new(base + Vector3.new(0, 0.24 + length*0.5, 0))
	model.Head.CFrame = CFrame.new(base + Vector3.new(0, math.max(height - 0.08, 0.24), 0))
	model:SetAttribute("Height", height)
	model:SetAttribute("Lowering", removing)
end

function JackVisual.Create(parent: Instance, ownerId: number, base: Vector3, height: number, onControl): (Model, {RBXScriptConnection})
	local model = Instance.new("Model")
	model.Name = "VehicleJack"
	model:SetAttribute(config.MODEL_ATTRIBUTE, true)
	model:SetAttribute("OwnerUserId", ownerId)
	local connections = {}
	local ok, problem = pcall(function()
		local foot = part("Base", Vector3.new(2, 0.24, 2), model, config.COLOR)
		part("Column", Vector3.new(0.35, 1, 0.35), model, Color3.fromRGB(170, 175, 180))
		part("Head", Vector3.new(1.4, 0.16, 1.4), model, config.COLOR)
		model.PrimaryPart = foot
		for index, descriptor in {
			{action = "Raise", text = "Поднять", key = config.RAISE_KEY, gamepad = Enum.KeyCode.ButtonY},
			{action = "Lower", text = "Опустить", key = config.LOWER_KEY, gamepad = Enum.KeyCode.ButtonB},
			{action = "Remove", text = "Опустить и убрать", key = config.REMOVE_KEY, gamepad = Enum.KeyCode.ButtonX},
		} do
			local prompt = Instance.new("ProximityPrompt")
			prompt.Name, prompt.ActionText, prompt.ObjectText = descriptor.action, descriptor.text, "Домкрат"
			prompt.KeyboardKeyCode, prompt.GamepadKeyCode = descriptor.key, descriptor.gamepad
			prompt.MaxActivationDistance, prompt.HoldDuration = config.MAX_USE_DISTANCE, 0
			prompt.RequiresLineOfSight = false -- JackServer independently verifies line of sight and ownership.
			prompt.Exclusivity = Enum.ProximityPromptExclusivity.AlwaysShow
			prompt.UIOffset = Vector2.new(0, (index - 2) * 76)
			prompt.Parent = foot
			table.insert(connections, prompt.Triggered:Connect(function(player) onControl(player, model, descriptor.action) end))
		end
		JackVisual.Update(model, base, height, false)
		model.Parent = parent
	end)
	if not ok then
		for _, connection in connections do connection:Disconnect() end
		model:Destroy()
		error(problem)
	end
	return model, connections
end

return table.freeze(JackVisual)
