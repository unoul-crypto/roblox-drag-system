-- Geometry and height changes have no UI or server state dependencies.
local JackMotion = {}

function JackMotion.bounds(parts: {BasePart}): (Vector3, Vector3)
	local minimum = Vector3.new(math.huge, math.huge, math.huge)
	local maximum = -minimum
	for _, part in parts do
		local half = part.Size * 0.5
		for _, x in {-1, 1} do for _, y in {-1, 1} do for _, z in {-1, 1} do
			local point = part.CFrame:PointToWorldSpace(Vector3.new(half.X*x, half.Y*y, half.Z*z))
			minimum, maximum = minimum:Min(point), maximum:Max(point)
		end end end
	end
	return minimum, maximum
end

function JackMotion.advance(height: number, goal: number, dt: number, config): number
	if not (dt > 0 and dt < math.huge) then return height end
	dt = math.min(dt, 0.1)
	local difference = goal - height
	local distance = math.min(math.abs(difference), math.max(config.LIFT_SPEED, 0) * dt)
	if config.RESPONSE_TIME > 0 then
		distance = math.min(distance, math.abs(difference) * (1 - math.exp(-dt / config.RESPONSE_TIME)))
	end
	return height + math.sign(difference) * distance
end

return table.freeze(JackMotion)
