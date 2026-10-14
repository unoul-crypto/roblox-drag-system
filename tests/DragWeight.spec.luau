return function(dragWeight, config)
	local checks = 0
	local function check(condition: boolean, message: string)
		assert(condition, message)
		checks += 1
	end
	local function nearlyEqual(actual: number, expected: number): boolean
		return math.abs(actual - expected) <= math.max(math.abs(expected), 1) * 1e-9
	end

	for _, invalid in {false, "1", -1, -math.huge, math.huge, 0 / 0, 0} do
		check(dragWeight.normalize(invalid) == 0, "Invalid weight must become zero")
	end
	check(dragWeight.normalize(nil) == 0, "Missing weight must become zero")
	for _, valid in {1e-300, 0.01, 0.1, 1, 10, 1e308} do
		check(dragWeight.normalize(valid) == valid, "Positive finite weights must be preserved")
	end

	local parameters = {
		positionResponsiveness = {
			config.PHYSICS_POSITION_RESPONSIVENESS,
			config.PHYSICS_LIGHT_POSITION_RESPONSIVENESS,
			config.PHYSICS_MIN_POSITION_RESPONSIVENESS,
		},
		maxVelocity = {
			config.PHYSICS_MAX_VELOCITY,
			config.PHYSICS_LIGHT_MAX_VELOCITY,
			config.PHYSICS_MIN_MAX_VELOCITY,
		},
		forceGravityMultiplier = {
			config.PHYSICS_FORCE_GRAVITY_MULTIPLIER,
			config.PHYSICS_LIGHT_FORCE_GRAVITY_MULTIPLIER,
			config.PHYSICS_MIN_FORCE_GRAVITY_MULTIPLIER,
		},
		orientationResponsiveness = {
			config.PHYSICS_ORIENTATION_RESPONSIVENESS,
			config.PHYSICS_LIGHT_ORIENTATION_RESPONSIVENESS,
			config.PHYSICS_MIN_ORIENTATION_RESPONSIVENESS,
		},
		orientationTorqueMultiplier = {
			config.PHYSICS_ORIENTATION_TORQUE_MULTIPLIER,
			config.PHYSICS_LIGHT_ORIENTATION_TORQUE_MULTIPLIER,
			config.PHYSICS_MIN_ORIENTATION_TORQUE_MULTIPLIER,
		},
		maxAngularVelocity = {
			config.PHYSICS_MAX_ANGULAR_VELOCITY,
			config.PHYSICS_LIGHT_MAX_ANGULAR_VELOCITY,
			config.PHYSICS_MIN_MAX_ANGULAR_VELOCITY,
		},
	}

	local zero = dragWeight.getPhysicsSettings(0, config)
	local light = dragWeight.getPhysicsSettings(0.01, config)
	local reference = dragWeight.getPhysicsSettings(1, config)
	local huge = dragWeight.getPhysicsSettings(1e308, config)
	for name, limits in parameters do
		check(nearlyEqual(zero[name], limits[2]), name .. " must approach the light limit at zero")
		check(nearlyEqual(reference[name], limits[1]), name .. " must use the reference at weight 1")
		check(light[name] > reference[name], name .. " must retain a faster response at 0.01 than at 1")
		check(nearlyEqual(huge[name], limits[3]), name .. " must reach its heavy floor")
	end
	check(light.positionResponsiveness > config.PHYSICS_LIGHT_POSITION_RESPONSIVENESS * 0.9,
		"Weight 0.01 must respond close to the configured light limit")
	check(light.maxVelocity > config.PHYSICS_LIGHT_MAX_VELOCITY * 0.9, "Weight 0.01 must move almost at the light speed limit")
	check(light.forceGravityMultiplier > reference.forceGravityMultiplier * 20, "Light weights need enough force to follow quickly")
	check(light.orientationResponsiveness > 100, "Light rotations must also respond quickly")

	-- Check the full range, including near zero and very large finite inputs.
	local previous = zero
	for _, weight in {1e-300, 1e-8, 0.0001, 0.001, 0.01, 0.1, 0.5, 1, 2, 10, 100, 1e6, 1e308} do
		local current = dragWeight.getPhysicsSettings(weight, config)
		for name, limits in parameters do
			local value = current[name]
			check(value == value and value < math.huge, name .. " must stay finite")
			check(value >= limits[3] and value <= limits[2], name .. " must stay within its limits")
			check(value <= previous[name], name .. " must not get stronger as weight increases")
		end
		previous = current
	end

	-- Nearby weights should not introduce a hidden threshold or a large jump.
	for _, weight in {0.0001, 0.01, 0.1, 0.5, 1, 10} do
		local before = dragWeight.getPhysicsSettings(weight, config)
		local after = dragWeight.getPhysicsSettings(weight + 1e-7, config)
		for name in parameters do
			check(math.abs(after[name] - before[name]) / before[name] < 1e-4, name .. " must vary continuously")
		end
	end

	local scaledConfig = table.clone(config)
	scaledConfig.PHYSICS_WEIGHT_RESISTANCE_SCALE = 2
	local scaled = dragWeight.getPhysicsSettings(0.5, scaledConfig)
	for name in parameters do
		check(nearlyEqual(scaled[name], reference[name]), name .. " must respect the configured weight scale")
	end
	print("DragWeight: " .. checks .. " checks passed")
	for _, weight in {0.01, 0.1, 0.5, 1} do
		local settings = dragWeight.getPhysicsSettings(weight, config)
		print(string.format("weight=%g: responsiveness=%.2f, maxVelocity=%.2f, forceMultiplier=%.2f",
			weight, settings.positionResponsiveness, settings.maxVelocity, settings.forceGravityMultiplier))
	end
end
