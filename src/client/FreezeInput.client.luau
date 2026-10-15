local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local config = require(ReplicatedStorage.Shared.FreezeConfig)
local remote = ReplicatedStorage:WaitForChild("UnfreezeOwnModels") :: RemoteEvent

UserInputService.InputBegan:Connect(function(input, processed)
	if not processed and not UserInputService:GetFocusedTextBox() and input.KeyCode == config.UNFREEZE_KEY then
		remote:FireServer()
	end
end)
