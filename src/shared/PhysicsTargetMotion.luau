-- Pure target trajectory. Only AlignPosition moves the actual assembly.
local PhysicsTargetMotion = {}

export type Settings = {
	maxSpeed: number, acceleration: number, deceleration: number,
	responseTime: number, accelerationSmoothTime: number,
}
export type State = {position: Vector3, velocity: Vector3, acceleration: Vector3}
type Config = {
	PHYSICS_MAX_VELOCITY: number,
	PHYSICS_TARGET_MAX_SPEED: number,
	PHYSICS_TARGET_ACCELERATION: number,
	PHYSICS_TARGET_DECELERATION: number,
	PHYSICS_TARGET_RESPONSE_TIME: number,
	PHYSICS_TARGET_ACCELERATION_SMOOTH_TIME: number,
}

local function capped(value: Vector3, limit: number): Vector3
	local length = value.Magnitude
	return if length > limit then value * (limit / length) else value
end

function PhysicsTargetMotion.getSettings(weightedMaxVelocity: number, config: Config): Settings
	-- Reuse the existing weight curve; physical tuning remains independent.
	local ratio = math.max(weightedMaxVelocity / math.max(config.PHYSICS_MAX_VELOCITY, 0.001), 0.001)
	local accelerationSmoothTime = math.max(config.PHYSICS_TARGET_ACCELERATION_SMOOTH_TIME / ratio, 0)
	return {
		maxSpeed = math.max(math.min(config.PHYSICS_TARGET_MAX_SPEED, weightedMaxVelocity), 0),
		acceleration = math.max(config.PHYSICS_TARGET_ACCELERATION * ratio, 0.001),
		deceleration = math.max(config.PHYSICS_TARGET_DECELERATION * ratio, 0.001),
		-- Acceleration smoothing must not lag behind the velocity feedback loop.
		responseTime = math.max(config.PHYSICS_TARGET_RESPONSE_TIME / ratio, accelerationSmoothTime * 2, 0.001),
		accelerationSmoothTime = accelerationSmoothTime,
	}
end

function PhysicsTargetMotion.new(position: Vector3): State
	return {position = position, velocity = Vector3.zero, acceleration = Vector3.zero}
end

function PhysicsTargetMotion.reset(state: State, position: Vector3)
	state.position, state.velocity, state.acceleration = position, Vector3.zero, Vector3.zero
end

local function integrate(state: State, goal: Vector3, dt: number, settings: Settings)
	local offset = goal - state.position
	local distance = offset.Magnitude
	if distance < 1e-4 and state.velocity.Magnitude < 1e-3 and state.acceleration.Magnitude < 1e-2 then
		PhysicsTargetMotion.reset(state, goal)
		return
	end
	local desiredSpeed = math.min(settings.maxSpeed, distance / settings.responseTime,
		math.sqrt(2 * settings.deceleration * distance))
	local desiredVelocity = if distance > 1e-8 then offset * (desiredSpeed / distance) else Vector3.zero
	local previousVelocity = state.velocity
	local change = desiredVelocity - previousVelocity
	local braking = change:Dot(previousVelocity) < 0
	local limit = if braking then settings.deceleration else settings.acceleration
	local desiredAcceleration = capped(change * (1 / settings.responseTime), limit)
	local alpha = if settings.accelerationSmoothTime > 0
		then 1 - math.exp(-dt / settings.accelerationSmoothTime) else 1
	state.acceleration = capped(state.acceleration + (desiredAcceleration - state.acceleration) * alpha, limit)
	state.velocity = capped(previousVelocity + state.acceleration * dt, settings.maxSpeed)
	state.position += (previousVelocity + state.velocity) * (dt * 0.5)
end

function PhysicsTargetMotion.step(state: State, goal: Vector3, deltaTime: number, settings: Settings): Vector3
	-- Small deterministic steps prevent a low-frame-rate update from causing a large leap.
	if deltaTime ~= deltaTime or deltaTime <= 0 then return state.position end
	local remaining = math.min(deltaTime, 0.1)
	local maxStep = math.min(1 / 120, settings.responseTime * 0.25)
	while remaining > 1e-8 do
		local dt = math.min(remaining, maxStep)
		integrate(state, goal, dt, settings)
		remaining -= dt
	end
	return state.position
end

return table.freeze(PhysicsTargetMotion)
