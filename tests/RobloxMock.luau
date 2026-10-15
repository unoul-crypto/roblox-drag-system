-- Minimal engine adapter for server logic tests, not a physics simulator.
local Mock = {}

local function signal()
	local callbacks = {}
	local event = {}
	function event:Connect(callback)
		local connection = {Connected = true}
		function connection:Disconnect() self.Connected = false end
		callbacks[connection] = callback
		return connection
	end
	function event:Fire(...)
		for connection, callback in table.clone(callbacks) do
			if connection.Connected then callback(...) end
		end
	end
	function event:ListenerCount()
		local count = 0
		for connection in callbacks do if connection.Connected then count += 1 end end
		return count
	end
	return event
end

local Vector = {}
Vector.__index = function(v, key)
	if key == "Magnitude" then return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) end
	return Vector[key]
end
local function vector(x, y, z) return setmetatable({_kind = "Vector3", X = x, Y = y, Z = z}, Vector) end
Vector.__add = function(a, b) return vector(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
Vector.__sub = function(a, b) return vector(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
Vector.__mul = function(a, b) return vector(a.X * b, a.Y * b, a.Z * b) end
Vector.__unm = function(a) return a * -1 end
function Vector:Min(b) return vector(math.min(self.X, b.X), math.min(self.Y, b.Y), math.min(self.Z, b.Z)) end
function Vector:Max(b) return vector(math.max(self.X, b.X), math.max(self.Y, b.Y), math.max(self.Z, b.Z)) end
function Vector:Dot(b) return self.X * b.X + self.Y * b.Y + self.Z * b.Z end
function Vector:Cross(b) return vector(self.Y*b.Z-self.Z*b.Y, self.Z*b.X-self.X*b.Z, self.X*b.Y-self.Y*b.X) end
Mock.Vector3 = {new = vector, one = vector(1, 1, 1), zero = vector(0, 0, 0), yAxis = vector(0, 1, 0)}

local Frame = {}
local function frame(position, matrix)
	return setmetatable({_kind = "CFrame", Position = position,
		matrix = matrix or {1, 0, 0, 0, 1, 0, 0, 0, 1}}, Frame)
end
local function transform(matrix, point)
	return vector(matrix[1] * point.X + matrix[2] * point.Y + matrix[3] * point.Z,
		matrix[4] * point.X + matrix[5] * point.Y + matrix[6] * point.Z,
		matrix[7] * point.X + matrix[8] * point.Y + matrix[9] * point.Z)
end
Frame.__index = function(frame, key)
	local matrix = frame.matrix
	if key == "Rotation" then return Mock.CFrame.newWithMatrix(vector(0, 0, 0), table.clone(matrix)) end
	if key == "XVector" or key == "RightVector" then return vector(matrix[1], matrix[4], matrix[7]) end
	if key == "YVector" then return vector(matrix[2], matrix[5], matrix[8]) end
	if key == "UpVector" then return vector(matrix[2], matrix[5], matrix[8]) end
	if key == "LookVector" then return vector(-matrix[3], -matrix[6], -matrix[9]) end
	if key == "ZVector" then return vector(matrix[3], matrix[6], matrix[9]) end
	return Frame[key]
end
Mock.CFrame = {new = function(x, y, z)
	local position = if type(x) == "table" then x else vector(x or 0, y or 0, z or 0)
	return frame(position)
end}
Mock.CFrame.newWithMatrix = frame
function Mock.CFrame.fromAxisAngle(axis, angle)
	local x, y, z = axis.X, axis.Y, axis.Z
	local c, s, t = math.cos(angle), math.sin(angle), 1 - math.cos(angle)
	return frame(vector(0, 0, 0), {
		t*x*x+c, t*x*y-s*z, t*x*z+s*y,
		t*x*y+s*z, t*y*y+c, t*y*z-s*x,
		t*x*z-s*y, t*y*z+s*x, t*z*z+c,
	})
end
Frame.__mul = function(a, b)
	local matrix = {}
	for row = 0, 2 do
		for col = 1, 3 do
			local index = row * 3 + col
			matrix[index] = a.matrix[row*3+1]*b.matrix[col]
				+ a.matrix[row*3+2]*b.matrix[3+col] + a.matrix[row*3+3]*b.matrix[6+col]
		end
	end
	return frame(a.Position + transform(a.matrix, b.Position), matrix)
end
function Frame:Inverse()
	local m = self.matrix
	local inverse = {m[1], m[4], m[7], m[2], m[5], m[8], m[3], m[6], m[9]}
	return frame(transform(inverse, -self.Position), inverse)
end
function Frame:PointToObjectSpace(point) return self:Inverse():PointToWorldSpace(point) end
function Frame:PointToWorldSpace(point) return self.Position + transform(self.matrix, point) end
function Frame:ToObjectSpace(other) return self:Inverse() * other end
function Frame:Lerp(other, alpha)
	-- The adapter only approximates native rotation interpolation; tests use identity rotation here.
	return frame(self.Position + (other.Position - self.Position) * alpha, other.matrix)
end

local methods = {}
local instances = {}
local meta = {}
meta.__index = function(object, key)
	if methods[key] then return methods[key] end
	if key == "WorldAxis" and object.ClassName == "Attachment" then return object.Parent.CFrame.XVector end
	if key == "Position" and object._properties.Position == nil then return object._properties.CFrame.Position end
	if object._properties[key] ~= nil then return object._properties[key] end
	for _, child in object._children do if child.Name == key then return child end end
	return nil
end
meta.__newindex = function(object, key, value)
	local previous = object._properties[key]
	if key == "Parent" and previous ~= value and previous then
		local removed = {object}
		for _, child in object:GetDescendants() do table.insert(removed, child) end
		local ancestor = previous
		while ancestor do
			for _, item in removed do ancestor.DescendantRemoving:Fire(item) end
			ancestor = ancestor.Parent
		end
	end
	if key == "Parent" and previous then
		local index = table.find(previous._children, object)
		if index then table.remove(previous._children, index) end
	end
	object._properties[key] = value
	if key == "Anchored" and previous ~= value then
		object._properties.networkOwner, object._properties.networkAuto = nil, true
	end
	if key == "Parent" then
		if value then table.insert(value._children, object) end
		if value and previous ~= value then value.ChildAdded:Fire(object) end
		object.AncestryChanged:Fire(object, value)
		if value and previous ~= value then
			local added = {object}
			for _, child in object:GetDescendants() do table.insert(added, child) end
			local ancestor = value
			while ancestor do
				for _, item in added do ancestor.DescendantAdded:Fire(item) end
				ancestor = ancestor.Parent
			end
		end
	end
	if object._signals[key] then object._signals[key]:Fire() end
end
Mock.Instance = {new = function(class)
	if Mock.failNextClass == class then
		Mock.failNextClass = nil
		error("Injected engine construction failure")
	end
	local object = setmetatable({
		_kind = "Instance", _children = {}, _signals = {}, _attributes = {},
		_properties = {ClassName = class, Name = class, Enabled = true,
			Anchored = false, CanCollide = true, AssemblyMass = 1,
			Size = vector(2, 2, 2), CFrame = Mock.CFrame.new(),
			Destroying = signal(), AncestryChanged = signal(), OnServerEvent = signal(),
			DescendantAdded = signal(), DescendantRemoving = signal(), networkAuto = true,
			CharacterRemoving = signal(), CharacterAdded = signal(), ChildAdded = signal(), Died = signal(),
			Event = signal(), CollisionGroup = "Default",
			Touched = signal(), CanTouch = true,
			Health = 100, state = "HumanoidStateType.Running"},
	}, meta)
	table.insert(instances, object)
	return object
end}
function methods:IsA(class)
	return self.ClassName == class or class == "Instance"
		or (class == "BasePart" and (self.ClassName == "Part" or self.ClassName == "MeshPart" or self.ClassName == "Seat" or self.ClassName == "VehicleSeat"))
end
function methods:IsDescendantOf(parent)
	local current = self.Parent
	while current do if current == parent then return true end; current = current.Parent end
	return false
end
function methods:GetChildren() return table.clone(self._children) end
function methods:GetDescendants()
	local result = {}
	for _, child in self._children do
		table.insert(result, child)
		for _, descendant in child:GetDescendants() do table.insert(result, descendant) end
	end
	return result
end
function methods:FindFirstChild(name, recursive)
	for _, child in if recursive then self:GetDescendants() else self._children do if child.Name == name then return child end end
	return nil
end
function methods:FindFirstChildWhichIsA(class, recursive)
	for _, child in if recursive then self:GetDescendants() else self._children do
		if child:IsA(class) then return child end
	end
	return nil
end
function methods:GetAttribute(name) return self._attributes[name] end
function methods:SetAttribute(name, value) self._attributes[name] = value end
function methods:GetPropertyChangedSignal(name)
	self._signals[name] = self._signals[name] or signal()
	return self._signals[name]
end
function methods:Destroy()
	if self._properties.destroyed then return end
	self._properties.destroyed = true
	self.Destroying:Fire()
	for _, child in self:GetChildren() do child:Destroy() end
	self.Parent = nil
end
function methods:GetPivot() return if self.PrimaryPart then self.PrimaryPart.CFrame else self.CFrame end
function methods:GetBoundingBox()
	local minimum = vector(math.huge, math.huge, math.huge)
	local maximum = -minimum
	for _, part in self:GetDescendants() do
		if part:IsA("BasePart") then
			minimum = minimum:Min(part.Position - part.Size * 0.5)
			maximum = maximum:Max(part.Position + part.Size * 0.5)
		end
	end
	return Mock.CFrame.new((minimum + maximum) * 0.5), maximum - minimum
end
function methods:GetClosestPointOnSurface(point)
	local relative = point - self.Position
	local half = self.Size * 0.5
	return self.Position + vector(math.clamp(relative.X, -half.X, half.X),
		math.clamp(relative.Y, -half.Y, half.Y), math.clamp(relative.Z, -half.Z, half.Z))
end
function methods:CanSetNetworkOwnership() return self._properties.canSetOwnership ~= false end
function methods:SetNetworkOwner(player)
	if self._properties.failOwnership then error("Injected ownership failure") end
	self._properties.networkOwner, self._properties.networkAuto = player, false
end
function methods:GetNetworkOwner() return self._properties.networkOwner end
function methods:GetNetworkOwnershipAuto() return self._properties.networkAuto end
function methods:SetNetworkOwnershipAuto() self._properties.networkOwner, self._properties.networkAuto = nil, true end
function methods:FireClient(player, ...) self._properties.lastClientEvent = {player, ...} end
function methods:Move(direction) self._properties.moveDirection = direction end
function methods:GetState() return self.state end
function methods:GetTouchingParts() return (Mock.touching or {})[self] or {} end
function methods:Fire(...) self.Event:Fire(...) end

Mock.workspace = Mock.Instance.new("Workspace")
Mock.workspace.Gravity = 196.2
local tags, removedSignals, addedSignals = {}, {}, {}
local collection = {}
function collection:HasTag(object, tag) return tags[tag] ~= nil and tags[tag][object] == true end
function collection:AddTag(object, tag)
	tags[tag] = tags[tag] or {}
	if tags[tag][object] then return end
	tags[tag][object] = true
	if addedSignals[tag] then addedSignals[tag]:Fire(object) end
end
function collection:GetTagged(tag)
	local result = {}
	for object in tags[tag] or {} do table.insert(result, object) end
	return result
end
function collection:RemoveTag(object, tag)
	if tags[tag] then tags[tag][object] = nil end
	if removedSignals[tag] then removedSignals[tag]:Fire(object) end
end
function collection:GetInstanceRemovedSignal(tag)
	removedSignals[tag] = removedSignals[tag] or signal()
	return removedSignals[tag]
end
function collection:GetInstanceAddedSignal(tag)
	addedSignals[tag] = addedSignals[tag] or signal()
	return addedSignals[tag]
end
local players = Mock.Instance.new("Players")
players.PlayerAdded, players.PlayerRemoving = signal(), signal()
function players:GetPlayerByUserId(id)
	for _, player in self:GetChildren() do if player.UserId == id then return player end end
	return nil
end
function players:GetPlayers() return self:GetChildren() end
Mock.services = {CollectionService = collection, Players = players,
	ReplicatedStorage = Mock.Instance.new("ReplicatedStorage"), RunService = {Heartbeat = signal(), PreSimulation = signal()}, TweenService = {}}
Mock.services.PhysicsService = {CollisionGroupsAreCollidable = function(_, a, b)
	return not (Mock.blockedCollisionGroups and (Mock.blockedCollisionGroups[a .. ":" .. b]
		or Mock.blockedCollisionGroups[b .. ":" .. a]))
end}
Mock.params = {new = function() return {} end}
function Mock.workspace:Blockcast() return nil end
function Mock.workspace:Raycast(origin, direction, params)
	Mock.lastRaycast = {origin = origin, direction = direction, params = params}
	return Mock.rayBlocker
end
function Mock.workspace:GetPartBoundsInBox(frame, size, params)
	if Mock.boundsQuery then return Mock.boundsQuery(frame, size, params) end
	return {}
end
function Mock.workspace:GetPartsInPart(part) return (Mock.overlaps or {})[part] or {} end
function Mock.services.TweenService:SmoothDamp(current, target, velocity, smoothTime, maxSpeed, dt)
	self.lastCall = {smoothTime = smoothTime, deltaTime = dt, maxSpeed = maxSpeed}
	return current:Lerp(target, 1 - math.exp(-dt / smoothTime)), velocity
end
local actions = {bindings = {}}
function actions:BindActionAtPriority(name, callback, _, priority, ...)
	self.bindings[name] = {callback = callback, priority = priority, inputs = {...}}
end
function actions:UnbindAction(name) self.bindings[name] = nil end
local inputs = {keys = {}, focused = nil}
function inputs:IsKeyDown(key) return self.keys[key] == true end
function inputs:GetFocusedTextBox() return self.focused end
Mock.services.ContextActionService, Mock.services.UserInputService = actions, inputs
Mock.game = {GetService = function(_, name) return assert(Mock.services[name], name) end}
Mock.Enum = setmetatable({}, {__index = function(_, key) return setmetatable({}, {__index = function(_, value) return key .. "." .. value end}) end})
Mock.Enum.ContextActionPriority = {High = {Value = 3000}}
Mock.Color3 = {fromRGB = function(...) return {...} end, new = function(...) return {...} end}
function Mock.typeof(value) return if type(value) == "table" and value._kind then value._kind else typeof(value) end
function Mock.part(name, x, parent)
	local part = Mock.Instance.new("Part")
	part.Name, part.CFrame, part.Parent = name, Mock.CFrame.new(x, 0, 0), parent or Mock.workspace
	return part
end
function Mock.player(id)
	local player = Mock.Instance.new("Player")
	player.UserId, player.Parent = id, players
	player.CameraMinZoomDistance, player.CameraMaxZoomDistance = 0.5, 128
	player.Character = Mock.Instance.new("Model")
	player.Character.Parent = Mock.workspace
	Mock.part("HumanoidRootPart", 0, player.Character)
	local humanoid = Mock.Instance.new("Humanoid"); humanoid.Parent = player.Character
	players.PlayerAdded:Fire(player)
	return player
end

return Mock
