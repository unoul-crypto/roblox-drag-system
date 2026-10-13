local ObjectTargets = require(script.Parent.ObjectTargets)
local ObjectMechanisms = {PRESERVE_ATTRIBUTE = "PreserveMechanism"}

function ObjectMechanisms.isPreserved(target: Instance): boolean
	return target:IsA("Model") and target:GetAttribute(ObjectMechanisms.PRESERVE_ATTRIBUTE) == true
end

-- A prepared mechanism owns its internal joints. Only its mounting part can be welded externally.
function ObjectMechanisms.getWeldParts(target: ObjectTargets.Target): {BasePart}
	if not ObjectMechanisms.isPreserved(target) then return ObjectTargets.getParts({target}) end
	local mount = (target :: Model).PrimaryPart
	if not mount or not mount:IsDescendantOf(target) then return {} end
	return {mount}
end

function ObjectMechanisms.hasOccupant(target: ObjectTargets.Target): boolean
	for _, part in ObjectTargets.getParts({target}) do
		if (part:IsA("Seat") or part:IsA("VehicleSeat")) and (part :: Seat).Occupant then return true end
	end
	return false
end

return table.freeze(ObjectMechanisms)
