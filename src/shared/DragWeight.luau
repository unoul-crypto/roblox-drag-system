-- Pure weight calculations shared by the client/server and standalone tests.
local DragWeight = {}

export type PhysicsSettings = {
	positionResponsiveness: number,
	maxVelocity: number,
	forceGravityMultiplier: number,
	orientationResponsiveness: number,
	orientationTorqueMultiplier: number,
	maxAngularVelocity: number,
}

type PhysicsConfig = {
	PHYSICS_WEIGHT_RESISTANCE_SCALE: number,
	PHYSICS_POSITION_RESPONSIVENESS: number,
	PHYSICS_LIGHT_POSITION_RESPONSIVENESS: number,
	PHYSICS_MIN_POSITION_RESPONSIVENESS: number,
	PHYSICS_MAX_VELOCITY: number,
	PHYSICS_LIGHT_MAX_VELOCITY: number,
	PHYSICS_MIN_MAX_VELOCITY: number,
	PHYSICS_FORCE_GRAVITY_MULTIPLIER: number,
	PHYSICS_LIGHT_FORCE_GRAVITY_MULTIPLIER: number,
	PHYSICS_MIN_FORCE_GRAVITY_MULTIPLIER: number,
	PHYSICS_ORIENTATION_RESPONSIVENESS: number,
	PHYSICS_LIGHT_ORIENTATION_RESPONSIVENESS: number,
	PHYSICS_MIN_ORIENTATION_RESPONSIVENESS: number,
	PHYSICS_ORIENTATION_TORQUE_MULTIPLIER: number,
	PHYSICS_LIGHT_ORIENTATION_TORQUE_MULTIPLIER: number,
	PHYSICS_MIN_ORIENTATION_TORQUE_MULTIPLIER: number,
	PHYSICS_MAX_ANGULAR_VELOCITY: number,
	PHYSICS_LIGHT_MAX_ANGULAR_VELOCITY: number,
	PHYSICS_MIN_MAX_ANGULAR_VELOCITY: number,
}

function DragWeight.normalize(value: any): number
	if typeof(value) ~= "number" or value ~= value or value <= 0 or value == math.huge then
		return 0
	end
	return value
end

local function weightedLimit(weight: number, reference: number, light: number, minimum: number): number
	-- Smooth bounded inverse: light at 0, reference at 1, then the heavy floor.
	-- No division by weight or thresholds that make tiny weights behave alike.
	return math.max(light / (1 + weight * (light / reference - 1)), minimum)
end

function DragWeight.getPhysicsSettings(weight: number, config: PhysicsConfig): PhysicsSettings
	local scaledWeight = DragWeight.normalize(weight) * config.PHYSICS_WEIGHT_RESISTANCE_SCALE
	return {
		positionResponsiveness = weightedLimit(scaledWeight,
			config.PHYSICS_POSITION_RESPONSIVENESS,
			config.PHYSICS_LIGHT_POSITION_RESPONSIVENESS,
			config.PHYSICS_MIN_POSITION_RESPONSIVENESS),
		maxVelocity = weightedLimit(scaledWeight,
			config.PHYSICS_MAX_VELOCITY,
			config.PHYSICS_LIGHT_MAX_VELOCITY,
			config.PHYSICS_MIN_MAX_VELOCITY),
		forceGravityMultiplier = weightedLimit(scaledWeight,
			config.PHYSICS_FORCE_GRAVITY_MULTIPLIER,
			config.PHYSICS_LIGHT_FORCE_GRAVITY_MULTIPLIER,
			config.PHYSICS_MIN_FORCE_GRAVITY_MULTIPLIER),
		orientationResponsiveness = weightedLimit(scaledWeight,
			config.PHYSICS_ORIENTATION_RESPONSIVENESS,
			config.PHYSICS_LIGHT_ORIENTATION_RESPONSIVENESS,
			config.PHYSICS_MIN_ORIENTATION_RESPONSIVENESS),
		orientationTorqueMultiplier = weightedLimit(scaledWeight,
			config.PHYSICS_ORIENTATION_TORQUE_MULTIPLIER,
			config.PHYSICS_LIGHT_ORIENTATION_TORQUE_MULTIPLIER,
			config.PHYSICS_MIN_ORIENTATION_TORQUE_MULTIPLIER),
		maxAngularVelocity = weightedLimit(scaledWeight,
			config.PHYSICS_MAX_ANGULAR_VELOCITY,
			config.PHYSICS_LIGHT_MAX_ANGULAR_VELOCITY,
			config.PHYSICS_MIN_MAX_ANGULAR_VELOCITY),
	}
end

return table.freeze(DragWeight)
