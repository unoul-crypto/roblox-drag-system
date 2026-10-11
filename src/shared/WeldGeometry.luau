local WeldGeometry = {}
export type Contact = {
	part0: BasePart,
	part1: BasePart,
	point0: Vector3,
	point1: Vector3,
	distance: number,
}

function WeldGeometry.closestContact(parts0: {BasePart}, parts1: {BasePart}): Contact?
	local best: Contact? = nil
	for _, part0 in parts0 do
		for _, part1 in parts1 do
			-- Alternating closest-surface projections also handle long/rotated parts.
			-- Use both starting centers to avoid a one-sided result for meshes.
			for _, start in {part0.Position, part1.Position} do
				local point0 = part0:GetClosestPointOnSurface(start)
				local point1 = part1:GetClosestPointOnSurface(point0)
				for _ = 1, 12 do
					local nextPoint0 = part0:GetClosestPointOnSurface(point1)
					local nextPoint1 = part1:GetClosestPointOnSurface(nextPoint0)
					local change = (nextPoint0 - point0).Magnitude + (nextPoint1 - point1).Magnitude
					point0, point1 = nextPoint0, nextPoint1
					if change < 0.0001 then break end
				end
				local distance = (point0 - point1).Magnitude
				if not best or distance < best.distance then
					best = {part0 = part0, part1 = part1, point0 = point0, point1 = point1, distance = distance}
				end
			end
		end
	end
	return best
end

return table.freeze(WeldGeometry)
