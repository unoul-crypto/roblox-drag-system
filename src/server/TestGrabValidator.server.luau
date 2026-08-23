local DragServer = require(script.Parent.DragServer)

local unregister = DragServer.RegisterGrabValidator(function(target: BasePart | Model, _playerUserId: number): boolean
	return target:GetAttribute("TestBlockDragging") ~= true
end)

script.Destroying:Connect(unregister)
