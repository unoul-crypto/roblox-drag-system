type DragTarget = BasePart | Model
type GrabValidator = (target: DragTarget, playerUserId: number) -> boolean

type ValidatorRecord = {
	callback: GrabValidator,
}

local DragServer = {}
local validators: {ValidatorRecord} = {}

function DragServer.RegisterGrabValidator(validator: GrabValidator): () -> ()
	assert(typeof(validator) == "function", "Grab validator must be a function")

	local record = {
		callback = validator,
	}
	table.insert(validators, record)

	local registered = true
	return function()
		if not registered then
			return
		end
		registered = false

		local index = table.find(validators, record)
		if index then
			table.remove(validators, index)
		end
	end
end

function DragServer.CanGrab(target: DragTarget, playerUserId: number): boolean
	-- Use a snapshot so validators may safely register or unregister checks while
	-- the current request is being evaluated.
	local snapshot = table.clone(validators)
	for _, record in snapshot do
		local succeeded, allowed = pcall(record.callback, target, playerUserId)
		if not succeeded then
			warn("DragSystem: a grab validator failed; the grab was denied:", allowed)
			return false
		end

		if allowed ~= true then
			return false
		end
	end

	return true
end

return table.freeze(DragServer)
