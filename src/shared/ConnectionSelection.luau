-- Read-only client view of replicated direct links. The server remains authoritative.
local ObjectTargets = require(script.Parent.ObjectTargets)
local config = require(script.Parent.WeldConfig)
local ConnectionSelection = {}

function ConnectionSelection.read(record)
	local a, b, marker = record:FindFirstChild("Target0"),record:FindFirstChild("Target1"),record:FindFirstChild("WeldPoint")
	if not a or not b or not a:IsA("ObjectValue") or not b:IsA("ObjectValue")
		or not ObjectTargets.isSupported(a.Value) or not ObjectTargets.isSupported(b.Value)
		or not marker or not marker:IsA("BasePart") or marker:GetAttribute(config.MARKER_ATTRIBUTE) ~= true
		or not ObjectTargets.isFiniteCFrame(marker.CFrame) then return nil end
	return {record=record,a=a.Value,b=b.Value,marker=marker}
end

function ConnectionSelection.records(folder, target)
	local result = {}
	if not folder then return result end
	for _, record in folder:GetChildren() do
		local link = ConnectionSelection.read(record)
		if link and (not target or link.a == target or link.b == target) then table.insert(result,link) end
	end
	return result
end

function ConnectionSelection.findTarget(hit, links)
	local endpoints = {}
	for _, link in links do endpoints[link.a],endpoints[link.b] = true,true end
	local part
	local current = hit
	while current and current ~= workspace do
		if endpoints[current] then
			if current:IsA("Model") then return current end
			if current:IsA("BasePart") then part = part or current end
		end
		current = current.Parent
	end
	return part
end

-- Spread overlapping icons; preserve the projected anchor for a connecting line.
-- Uses plain numbers so layout can be tested without a camera or GUI.
function ConnectionSelection.layout(points, width, height, size, gap)
	local placed = {}
	local half, stride = size*0.5,size+gap
	if width < size or height < size then return placed end
	for _, point in points do
		local function tryPlace(x,y)
			x,y = math.clamp(x,half,width-half),math.clamp(y,half,height-half)
			for _, other in placed do
				if math.abs(x-other.x) < stride and math.abs(y-other.y) < stride then return false end
			end
			table.insert(placed,{link=point.link,x=x,y=y,anchorX=point.x,anchorY=point.y})
			return true
		end
		if tryPlace(point.x,point.y) then continue end
		local found = false
		for radius = 1, #placed+1 do
			for dx = -radius,radius do
				for dy = -radius,radius do
					if math.abs(dx) ~= radius and math.abs(dy) ~= radius then continue end
					if tryPlace(point.x+dx*stride,point.y+dy*stride) then found = true; break end
				end
				if found then break end
			end
			if found then break end
		end
	end
	return placed
end

return table.freeze(ConnectionSelection)
