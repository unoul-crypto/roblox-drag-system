local config = require(script.Parent.DragConfig)

local DragCollision = {}

type DragTarget = BasePart | Model

local function getCastSize(size: Vector3): Vector3
	local reduction = config.COLLISION_PADDING * 2
	return Vector3.new(
		math.max(size.X - reduction, 0.05),
		math.max(size.Y - reduction, 0.05),
		math.max(size.Z - reduction, 0.05)
	)
end

local function makeRaycastParams(target: DragTarget, character: Model?): RaycastParams
	local excluded = {target}
	if character then
		table.insert(excluded, character)
	end

	local parameters = RaycastParams.new()
	parameters.FilterType = Enum.RaycastFilterType.Exclude
	parameters.FilterDescendantsInstances = excluded
	parameters.IgnoreWater = false
	parameters.RespectCanCollide = true
	return parameters
end

local function makeOverlapParams(target: DragTarget, character: Model?): OverlapParams
	local excluded = {target}
	if character then
		table.insert(excluded, character)
	end

	local parameters = OverlapParams.new()
	parameters.FilterType = Enum.RaycastFilterType.Exclude
	parameters.FilterDescendantsInstances = excluded
	parameters.RespectCanCollide = true
	return parameters
end

function DragCollision.getBoundingBox(target: DragTarget): (CFrame, Vector3)
	if target:IsA("BasePart") then
		return target.CFrame, target.Size
	end

	return target:GetBoundingBox()
end

local function isBoxBlocked(
	target: DragTarget,
	character: Model?,
	boxCFrame: CFrame,
	boxSize: Vector3
): boolean
	local parts = workspace:GetPartBoundsInBox(
		boxCFrame,
		getCastSize(boxSize),
		makeOverlapParams(target, character)
	)
	return #parts > 0
end

function DragCollision.resolvePivot(
	target: DragTarget,
	character: Model?,
	currentPivot: CFrame,
	desiredPivot: CFrame,
	boxOffset: CFrame,
	boxSize: Vector3
): CFrame
	local currentBox = currentPivot * boxOffset
	local desiredBox = desiredPivot * boxOffset
	local direction = desiredBox.Position - currentBox.Position
	local movementFraction = 1

	if direction.Magnitude > 0.0001 then
		local hit = workspace:Blockcast(
			currentBox,
			getCastSize(boxSize),
			direction,
			makeRaycastParams(target, character)
		)
		if hit then
			local allowedDistance = math.max(hit.Distance - config.COLLISION_PADDING, 0)
			movementFraction = math.min(allowedDistance / direction.Magnitude, 1)
		end
	end

	local candidate = currentPivot:Lerp(desiredPivot, movementFraction)
	if not isBoxBlocked(target, character, candidate * boxOffset, boxSize) then
		return candidate
	end

	-- If only the requested rotation intersects something, keep the last safe
	-- rotation while still allowing translation along the obstacle.
	local translationOnly = CFrame.new(candidate.Position) * currentPivot.Rotation
	if not isBoxBlocked(target, character, translationOnly * boxOffset, boxSize) then
		return translationOnly
	end

	return currentPivot
end

return table.freeze(DragCollision)
