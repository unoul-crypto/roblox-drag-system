local config = require(script.Parent.JackConfig)
local JackCollision = {}

local function isGround(part: BasePart, normal: Vector3): boolean
	return normal.Y >= config.MIN_GROUND_NORMAL_Y and (part:IsA("Terrain") or part.Anchored)
end

-- Sweep the real shape: a rotated tire's enclosing box can already intersect the floor.
function JackCollision.travel(parts: {BasePart}, excluded: {Instance}, distance: number): (number, boolean)
	local sign = math.sign(distance)
	local available, grounded, limited = math.abs(distance), false, false
	if available < 0.000001 then return 0, false end
	local function constrain(clearance: number, support: boolean)
		clearance = math.max(clearance, 0)
		if clearance > available + 0.00001 then return end
		if not limited or clearance < available - 0.00001 then grounded = support
		else grounded = grounded and support end
		available, limited = math.min(available, clearance), true
	end
	for _, part in parts do
		if not part.CanCollide then continue end
		local overlap = OverlapParams.new()
		overlap.FilterType, overlap.FilterDescendantsInstances = Enum.RaycastFilterType.Exclude, excluded
		overlap.RespectCanCollide, overlap.CollisionGroup = true, part.CollisionGroup
		overlap.Tolerance = config.COLLISION_PADDING
		-- Shapecasts skip initial intersections. Handle real existing contacts separately;
		-- allow movement away from a contact, so a grounded wheel can still be lifted.
		for _, other in workspace:GetPartsInPart(part, overlap) do
			local separation = part.Position - other:GetClosestPointOnSurface(part.Position)
			local length = separation.Magnitude
			if length < 0.00001 then constrain(0, false)
			elseif separation.Y * sign < -0.00001 then
				constrain(0, distance < 0 and isGround(other, separation * (1/length)))
			end
		end
		local params = RaycastParams.new()
		params.FilterType, params.FilterDescendantsInstances = Enum.RaycastFilterType.Exclude, excluded
		params.RespectCanCollide, params.CollisionGroup = true, part.CollisionGroup
		-- Only the released three-argument API is enabled in Studio. Sweep from the
		-- actual part and use the exact contact query above for existing intersections.
		local sweep = Vector3.new(0, sign * (math.abs(distance) + config.COLLISION_PADDING), 0)
		local hit = workspace:Shapecast(part, sweep, params)
		if hit then
			constrain(hit.Distance - config.COLLISION_PADDING, distance < 0 and isGround(hit.Instance, hit.Normal))
		end
	end
	return sign * available, grounded
end

return table.freeze(JackCollision)
