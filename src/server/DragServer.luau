local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ValidationRegistry = require(ReplicatedStorage.Shared.ValidationRegistry)
type DragTarget = BasePart | Model
type GrabValidator = (target: DragTarget, playerUserId: number) -> boolean

local DragServer = {}
local validators = ValidationRegistry.new("DragSystem", warn)

function DragServer.RegisterGrabValidator(validator: GrabValidator): () -> ()
	return validators:Register(validator)
end

function DragServer.CanGrab(target: DragTarget, playerUserId: number): boolean
	return validators:Check(target, playerUserId)
end

return table.freeze(DragServer)
