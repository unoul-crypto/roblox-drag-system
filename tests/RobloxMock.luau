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
Mock.Vector3 = {new = vector, one = vector(1, 1, 1), zero = vector(0, 0, 0)}

local Frame = {}
Frame.__index = function(frame, key)
	if key == "Rotation" then return Mock.CFrame.new() end
	if key == "XVector" then return vector(1, 0, 0) end
	if key == "YVector" then return vector(0, 1, 0) end
	if key == "ZVector" then return vector(0, 0, 1) end
	return Frame[key]
end
Mock.CFrame = {new = function(x, y, z)
	local position = if type(x) == "table" then x else vector(x or 0, y or 0, z or 0)
	return setmetatable({_kind = "CFrame", Position = position}, Frame)
end}
Frame.__mul = function(a, b) return Mock.CFrame.new(a.Position + b.Position) end
function Frame:Inverse() return Mock.CFrame.new(-self.Position) end
function Frame:PointToObjectSpace(point) return point - self.Position end
function Frame:PointToWorldSpace(point) return point + self.Position end
function Frame:ToObjectSpace(other) return self:Inverse() * other end

local methods = {}
local instances = {}
local meta = {}
meta.__index = function(object, key)
	if methods[key] then return methods[key] end
	if key == "Position" then return object._properties.CFrame.Position end
	if object._properties[key] ~= nil then return object._properties[key] end
	for _, child in object._children do if child.Name == key then return child end end
	return nil
end
meta.__newindex = function(object, key, value)
	local previous = object._properties[key]
	if key == "Parent" and previous then
		local index = table.find(previous._children, object)
		if index then table.remove(previous._children, index) end
	end
	object._properties[key] = value
	if key == "Parent" then
		if value then table.insert(value._children, object) end
		object.AncestryChanged:Fire(object, value)
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
			CharacterRemoving = signal()},
	}, meta)
	table.insert(instances, object)
	return object
end}
function methods:IsA(class)
	return self.ClassName == class or class == "Instance"
		or (class == "BasePart" and (self.ClassName == "Part" or self.ClassName == "MeshPart"))
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
function methods:FindFirstChild(name)
	for _, child in self._children do if child.Name == name then return child end end
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
function methods:CanSetNetworkOwnership() return true end
function methods:SetNetworkOwner(player) self._properties.networkOwner = player end
function methods:GetNetworkOwner() return self._properties.networkOwner end
function methods:SetNetworkOwnershipAuto() self._properties.networkOwner = nil end
function methods:FireClient(player, ...) self._properties.lastClientEvent = {player, ...} end

Mock.workspace = Mock.Instance.new("Workspace")
Mock.workspace.Gravity = 196.2
local tags, removedSignals = {}, {}
local collection = {}
function collection:HasTag(object, tag) return tags[tag] ~= nil and tags[tag][object] == true end
function collection:AddTag(object, tag) tags[tag] = tags[tag] or {}; tags[tag][object] = true end
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
local players = Mock.Instance.new("Players")
players.PlayerAdded, players.PlayerRemoving = signal(), signal()
function players:GetPlayerByUserId(id)
	for _, player in self:GetChildren() do if player.UserId == id then return player end end
	return nil
end
function players:GetPlayers() return self:GetChildren() end
Mock.services = {CollectionService = collection, Players = players,
	ReplicatedStorage = Mock.Instance.new("ReplicatedStorage"), RunService = {Heartbeat = signal()}, TweenService = {}}
Mock.game = {GetService = function(_, name) return assert(Mock.services[name], name) end}
Mock.Enum = setmetatable({}, {__index = function(_, key) return setmetatable({}, {__index = function(_, value) return key .. "." .. value end}) end})
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
	player.Character = Mock.Instance.new("Model")
	player.Character.Parent = Mock.workspace
	Mock.part("HumanoidRootPart", 0, player.Character)
	return player
end

return Mock
