-- Tagged interaction assemblies always use manual server ownership, including while idle.
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ObjectTargets = require(ReplicatedStorage.Shared.ObjectTargets)
local dragConfig = require(ReplicatedStorage.Shared.DragConfig)
local weldConfig = require(ReplicatedStorage.Shared.WeldConfig)
local ServerOwnership = {}
local started = false
type Record = {connections: {RBXScriptConnection}, parts: {[BasePart]: {RBXScriptConnection}}}
local records: {[Instance]: Record} = {}

function ServerOwnership.Claim(parts: {BasePart}): boolean
	local handled = {}
	for _, part in parts do
		if part:IsDescendantOf(workspace) and not part.Anchored then
			local root = part.AssemblyRootPart or part
			if not handled[root] and not root.Anchored then
				handled[root] = true
				local ok, owned = pcall(function()
					if root:GetNetworkOwner() == nil and not root:GetNetworkOwnershipAuto() then return true end
					if not root:CanSetNetworkOwnership() then return false end
					root:SetNetworkOwner(nil)
					return root:GetNetworkOwner() == nil and not root:GetNetworkOwnershipAuto()
				end)
				if not ok or not owned then return false end
			end
		end
	end
	return true
end

local function unwatch(target: Instance)
	local record = records[target]
	if not record then return end
	records[target] = nil
	for _, connection in record.connections do connection:Disconnect() end
	for _, connections in record.parts do
		for _, connection in connections do connection:Disconnect() end
	end
end

local function watch(target: Instance)
	if records[target] or not (target:IsA("BasePart") or target:IsA("Model")) then return end
	local record: Record = {connections = {}, parts = {}}
	records[target] = record
	local function addPart(part: Instance)
		if not part:IsA("BasePart") or record.parts[part] then return end
		local function claim() ServerOwnership.Claim({part :: BasePart}) end
		record.parts[part] = {
			part:GetPropertyChangedSignal("Anchored"):Connect(claim),
			part:GetPropertyChangedSignal("AssemblyRootPart"):Connect(claim),
		}
		claim()
	end
	local function refresh()
		for _, part in ObjectTargets.getParts({target :: any}) do addPart(part) end
		ServerOwnership.Claim(ObjectTargets.getParts({target :: any}))
	end
	table.insert(record.connections, target.AncestryChanged:Connect(refresh))
	table.insert(record.connections, target.Destroying:Connect(function() unwatch(target) end))
	if target:IsA("Model") then
		table.insert(record.connections, target.DescendantAdded:Connect(addPart))
		table.insert(record.connections, target.DescendantRemoving:Connect(function(part)
			local connections = record.parts[part]
			if connections then
				record.parts[part] = nil
				for _, connection in connections do connection:Disconnect() end
			end
		end))
	end
	refresh()
end

function ServerOwnership.Start()
	if started then return end
	started = true
	for _, tag in {dragConfig.TAG_NAME, weldConfig.TAG_NAME} do
		CollectionService:GetInstanceAddedSignal(tag):Connect(watch)
		CollectionService:GetInstanceRemovedSignal(tag):Connect(function(target)
			if not CollectionService:HasTag(target, dragConfig.TAG_NAME)
				and not CollectionService:HasTag(target, weldConfig.TAG_NAME) then unwatch(target) end
		end)
		for _, target in CollectionService:GetTagged(tag) do watch(target) end
	end
	local elapsed = 0
	RunService.Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed < dragConfig.SERVER_VALIDATION_INTERVAL then return end
		elapsed = 0
		for target in records do
			if target:IsDescendantOf(workspace) then ServerOwnership.Claim(ObjectTargets.getParts({target :: any})) end
		end
	end)
end

return table.freeze(ServerOwnership)
