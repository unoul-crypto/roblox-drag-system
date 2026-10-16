local ObjectTargets = require(script.Parent.ObjectTargets)
local HingeGeometry = {}
export type Endpoint = {target: ObjectTargets.Target, part: BasePart, point: Vector3, axis: Vector3}

function HingeGeometry.settings(config)
	local power = if type(config.POWER) == "number" and config.POWER == config.POWER then math.clamp(config.POWER, 0, 1) else 0
	return {power = power, force = config.MAX_FORCE*power, torque = config.MAX_TORQUE*power,
		distance = config.MAX_PULL_DISTANCE*power, speed = config.MAX_SPEED*power,
		angularSpeed = config.MAX_ANGULAR_SPEED*power}
end

function HingeGeometry.world(endpoint: Endpoint): (Vector3, Vector3)
	return endpoint.part.CFrame:PointToWorldSpace(endpoint.point), endpoint.part.CFrame.Rotation:PointToWorldSpace(endpoint.axis)
end

function HingeGeometry.valid(endpoint: Endpoint): boolean
	return type(endpoint) == "table" and ObjectTargets.isSupported(endpoint.target) and ObjectTargets.isSupported(endpoint.part)
		and (endpoint.part == endpoint.target or endpoint.part:IsDescendantOf(endpoint.target))
		and ObjectTargets.isFiniteCFrame(endpoint.part.CFrame)
		and typeof(endpoint.point) == "Vector3" and typeof(endpoint.axis) == "Vector3"
		and ObjectTargets.isFiniteVector(endpoint.point) and ObjectTargets.isFiniteVector(endpoint.axis)
		and math.abs(endpoint.axis.Magnitude-1) < 0.001
		and ObjectTargets.containsPoint(endpoint.part, endpoint.part.CFrame:PointToWorldSpace(endpoint.point))
end

function HingeGeometry.ready(a: Endpoint, b: Endpoint, config): boolean
	if not HingeGeometry.valid(a) or not HingeGeometry.valid(b) then return false end
	local point0, axis0 = HingeGeometry.world(a)
	local point1, axis1 = HingeGeometry.world(b)
	local velocity = a.part:GetVelocityAtPosition(point0) - b.part:GetVelocityAtPosition(point1)
	return (point0-point1).Magnitude <= config.CAPTURE_DISTANCE
		and axis0:Dot(axis1) >= math.cos(math.rad(config.CAPTURE_ANGLE))
		and ObjectTargets.isFiniteVector(velocity) and velocity.Magnitude <= config.CAPTURE_MAX_SPEED
end

function HingeGeometry.secondary(axis: Vector3): Vector3
	local reference = if math.abs(axis.Y) < 0.9 then Vector3.yAxis else Vector3.new(0,0,1)
	local projected = reference - axis*axis:Dot(reference)
	return projected * (1/projected.Magnitude)
end

return table.freeze(HingeGeometry)
