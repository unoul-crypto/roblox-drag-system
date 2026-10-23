-- Shape-dependent safety limits; native constraints still move the assembly.
local DragWeight = require(script.Parent.DragWeight)
local PhysicsDragStability = {}

function PhysicsDragStability.blend(size: Vector3, config): number
	if not config.PHYSICS_STABILITY_ENABLED then return 0 end
	local minimum = math.max(math.min(size.X,size.Y,size.Z),1e-6)
	local aspect = math.max(size.X,size.Y,size.Z)/minimum
	local start = math.max(config.PHYSICS_STABILITY_ASPECT_RATIO,1)
	local full = math.max(config.PHYSICS_STABILITY_FULL_ASPECT_RATIO,start+1e-6)
	local progress = math.clamp((aspect-start)/(full-start),0,1)
	return progress*progress*(3-2*progress)
end

function PhysicsDragStability.getSettings(weighted: DragWeight.PhysicsSettings, size: Vector3, config): DragWeight.PhysicsSettings
	local result = table.clone(weighted)
	local blend = PhysicsDragStability.blend(size,config)
	local caps = {
		positionResponsiveness = config.PHYSICS_STABILITY_POSITION_RESPONSIVENESS,
		orientationResponsiveness = config.PHYSICS_STABILITY_ORIENTATION_RESPONSIVENESS,
		maxVelocity = config.PHYSICS_STABILITY_MAX_VELOCITY,
		maxAngularVelocity = config.PHYSICS_STABILITY_MAX_ANGULAR_VELOCITY,
		forceGravityMultiplier = config.PHYSICS_STABILITY_FORCE_GRAVITY_MULTIPLIER,
	}
	for key, cap in caps do
		-- A safety limit must never make a heavy object faster or stronger.
		local limited = math.min(weighted[key],math.max(cap,0))
		result[key] = weighted[key]+(limited-weighted[key])*blend
	end
	return result
end

function PhysicsDragStability.forcePoint(frame: CFrame, center: Vector3, grabLocal: Vector3, blend: number): Vector3
	local centerLocal = frame:PointToObjectSpace(center)
	return grabLocal+(centerLocal-grabLocal)*blend
end

function PhysicsDragStability.forceTarget(grabGoal: Vector3, frame: CFrame, grabLocal: Vector3, forceLocal: Vector3): Vector3
	-- The center goal is NOT the cursor position. This identity keeps position
	-- error equal to (grabGoal - actualGrab) at every physical orientation.
	return grabGoal+frame.Rotation:PointToWorldSpace(forceLocal-grabLocal)
end

function PhysicsDragStability.rotate(current: CFrame, goal: CFrame, deltaTime: number, maxSpeed: number, responseTime: number): CFrame
	if responseTime <= 0 then return goal end
	if deltaTime ~= deltaTime or deltaTime <= 0 then return current end
	local remaining = math.min(deltaTime,0.1)
	while remaining > 1e-8 do
		local dt = math.min(remaining,1/120)
		local axis, angle = current:ToObjectSpace(goal):ToAxisAngle()
		if angle > math.pi then angle -= 2*math.pi end
		if angle < 0 then axis,angle = -axis,-angle end
		if angle < 1e-8 then return goal end
		local step = math.min(angle*(1-math.exp(-dt/responseTime)),math.max(maxSpeed,0)*dt)
		current = (current*CFrame.fromAxisAngle(axis,step)).Rotation
		remaining -= dt
	end
	return current
end

function PhysicsDragStability.mass(value: number): number
	-- Don't inflate a tiny physical mass to 0.001: that multiplies acceleration.
	return math.max(value,1e-9)
end

return table.freeze(PhysicsDragStability)
