-- Geometry and settings for manual controls, independent of input and camera ownership.
local DragManipulation = {}

type Settings = {
	MANIPULATION_ROTATION_SPEED: number,
	MANIPULATION_DISTANCE_STEP: number,
	MANIPULATION_MIN_DISTANCE: number,
	MANIPULATION_MAX_DISTANCE: number,
}

function DragManipulation.adjustDistance(distance: number, wheel: number, config: Settings): number
	local minimum = math.max(config.MANIPULATION_MIN_DISTANCE, 0.1)
	local maximum = math.max(config.MANIPULATION_MAX_DISTANCE, minimum)
	return math.clamp(distance - wheel * math.max(config.MANIPULATION_DISTANCE_STEP, 0), minimum, maximum)
end

function DragManipulation.rotate(rotation: CFrame, cameraRotation: CFrame,
	pitchInput: number, yawInput: number, deltaTime: number, config: Settings): CFrame
	local angle = math.rad(math.max(config.MANIPULATION_ROTATION_SPEED, 0)) * math.max(deltaTime, 0)
	-- Pitch follows the screen's horizontal axis; yaw follows the world's vertical axis.
	return (CFrame.fromAxisAngle(Vector3.yAxis, yawInput * angle)
		* CFrame.fromAxisAngle(cameraRotation.RightVector, pitchInput * angle) * rotation).Rotation
end

function DragManipulation.desiredPivot(grabPoint: Vector3, rotation: CFrame, localGrabPoint: Vector3): CFrame
	-- Rotate around the point held by the cursor, including off-center grabs.
	return CFrame.new(grabPoint) * rotation * CFrame.new(-localGrabPoint)
end

return table.freeze(DragManipulation)
