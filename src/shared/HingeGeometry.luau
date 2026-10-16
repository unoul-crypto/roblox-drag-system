local ObjectTargets = require(script.Parent.ObjectTargets)
local ObjectMechanisms = require(script.Parent.ObjectMechanisms)
local HingeGeometry = {}
export type Endpoint = {target: ObjectTargets.Target, part: BasePart, point: Vector3, axis: Vector3}

function HingeGeometry.settings(config)
	local power = if type(config.POWER) == "number" and config.POWER == config.POWER then math.clamp(config.POWER, 0, 1) else 0
	return {power = power, force = config.MAX_FORCE*power, torque = config.MAX_TORQUE*power,
		distance = config.MAX_PULL_DISTANCE*power, speed = config.MAX_SPEED*power,
		angularSpeed = config.MAX_ANGULAR_SPEED*power}
end

-- Higher response removes the soft controller's residual error near contact;
-- lower speed prevents the final correction from becoming a sudden lunge.
-- Neither force, torque nor the selected attachment positions are changed.
function HingeGeometry.driveSettings(distance: number, settings, config): (number, number)
	local progress = if config.FINISH_DISTANCE > 0 then 1-math.clamp(distance/config.FINISH_DISTANCE,0,1) else 0
	local blend = progress*progress*(3-2*progress)
	local response = config.RESPONSIVENESS+(config.FINISH_RESPONSIVENESS-config.RESPONSIVENESS)*blend
	local finishSpeed = math.min(settings.speed,math.max(config.FINISH_MAX_SPEED,0)*settings.power)
	return response, settings.speed+(finishSpeed-settings.speed)*blend
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
		-- A preserved mechanism uses a virtual point fixed to its mount, at the
		-- original clicked location on the model (which can lie on the tire).
		and (not ObjectMechanisms.isPreserved(endpoint.target) or endpoint.part == endpoint.target.PrimaryPart)
		and ObjectTargets.containsPoint(if ObjectMechanisms.isPreserved(endpoint.target) then endpoint.target else endpoint.part,
			endpoint.part.CFrame:PointToWorldSpace(endpoint.point))
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
