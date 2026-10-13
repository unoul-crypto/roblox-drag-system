local ObjectTargets = require(script.Parent.ObjectTargets)
local VehicleMotion = {}

-- Rolling direction depends on the axle orientation, including mirrored wheel modules.
function VehicleMotion.wheelVelocity(axis: Vector3, forward: Vector3, up: Vector3, speed: number): number
	if not ObjectTargets.isFiniteVector(axis) or not ObjectTargets.isFiniteVector(forward)
		or not ObjectTargets.isFiniteVector(up) or not (speed > 0 and speed < math.huge) then return 0 end
	local projection = axis:Cross(up):Dot(forward)
	if math.abs(projection) < 0.5 then return 0 end -- A sideways/vertical axle cannot drive forward.
	return if projection > 0 then speed else -speed
end

return table.freeze(VehicleMotion)
