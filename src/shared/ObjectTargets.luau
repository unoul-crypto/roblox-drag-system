local CollectionService = game:GetService("CollectionService")
local ObjectTargets = {}
export type Target = BasePart | Model

function ObjectTargets.isSupported(instance: any): boolean
	return typeof(instance) == "Instance"
		and instance:IsDescendantOf(workspace)
		and (instance:IsA("BasePart")
			or (instance:IsA("Model") and instance:FindFirstChildWhichIsA("BasePart", true) ~= nil))
end

function ObjectTargets.findTagged(hit: Instance?, tag: string): Target?
	local current = hit
	local taggedPart: BasePart? = nil
	while current and current ~= workspace do
		if CollectionService:HasTag(current, tag) and ObjectTargets.isSupported(current) then
			if current:IsA("Model") then return current end
			if current:IsA("BasePart") and not taggedPart then taggedPart = current end
		end
		current = current.Parent
	end
	return taggedPart
end

function ObjectTargets.getParts(targets: {Target}): {BasePart}
	local result = {}
	local seen = {}
	for _, target in targets do
		local parts = if target:IsA("BasePart") then {target} else target:GetDescendants()
		for _, part in parts do
			if part:IsA("BasePart") and not seen[part] then
				seen[part] = true
				table.insert(result, part)
			end
		end
	end
	return result
end

function ObjectTargets.getLockKeys(targets: {Target}, parts: {BasePart}): {Instance}
	local keys: {Instance} = table.clone(targets) :: {Instance}
	for _, part in parts do table.insert(keys, part) end
	return keys
end

function ObjectTargets.isFiniteVector(point: Vector3): boolean
	return point.X == point.X and math.abs(point.X) < math.huge
		and point.Y == point.Y and math.abs(point.Y) < math.huge
		and point.Z == point.Z and math.abs(point.Z) < math.huge
end

function ObjectTargets.containsPoint(target: Target, point: Vector3): boolean
	for _, part in ObjectTargets.getParts({target}) do
		local localPoint = part.CFrame:PointToObjectSpace(point)
		local half = part.Size * 0.5 + Vector3.one
		if math.abs(localPoint.X) <= half.X and math.abs(localPoint.Y) <= half.Y
			and math.abs(localPoint.Z) <= half.Z then return true end
	end
	return false
end

return table.freeze(ObjectTargets)
