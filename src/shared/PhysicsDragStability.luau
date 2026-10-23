-- Shape-dependent safety limits; native constraints still move the assembly.
local DragWeight = require(script.Parent.DragWeight)
local PhysicsDragStability = {}

function PhysicsDragStability.getSettings(weighted: DragWeight.PhysicsSettings, size: Vector3, config): DragWeight.PhysicsSettings
	local result = table.clone(weighted)
	if not config.PHYSICS_STABILITY_ENABLED then return result end
	local minimum = math.max(math.min(size.X,size.Y,size.Z),1e-6)
	local aspect = math.max(size.X,size.Y,size.Z)/minimum
	local start = math.max(config.PHYSICS_STABILITY_ASPECT_RATIO,1)
	local full = math.max(config.PHYSICS_STABILITY_FULL_ASPECT_RATIO,start+1e-6)
	local progress = math.clamp((aspect-start)/(full-start),0,1)
	local blend = progress*progress*(3-2*progress)
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

function PhysicsDragStability.mass(value: number): number
	-- Don't inflate a tiny physical mass to 0.001: that multiplies acceleration.
	return math.max(value,1e-9)
end

return table.freeze(PhysicsDragStability)
