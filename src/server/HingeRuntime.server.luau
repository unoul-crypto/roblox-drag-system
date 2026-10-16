local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local HingeServer = require(script.Parent.HingeServer)

local status = Instance.new("RemoteEvent")
status.Name, status.Parent = "HingeToolStatus",ReplicatedStorage
local click = Instance.new("RemoteFunction")
click.Name, click.Parent, click.OnServerInvoke = "HingeToolClick",ReplicatedStorage,HingeServer.Click
local cancel = Instance.new("RemoteEvent")
cancel.Name, cancel.Parent = "CancelHingeTool",ReplicatedStorage
cancel.OnServerEvent:Connect(HingeServer.Cancel)
HingeServer.Changed:Connect(function(player,id,reason)
	if player.Parent == Players then status:FireClient(player,id,reason) end
end)
Players.PlayerRemoving:Connect(HingeServer.RemovePlayer)
RunService.PreSimulation:Connect(HingeServer.Step)
