local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local VehicleServer = require(script.Parent.VehicleServer)

local remote = Instance.new("RemoteEvent")
remote.Name, remote.Parent = "VehicleControl", ReplicatedStorage
remote.OnServerEvent:Connect(VehicleServer.HandleInput)
Players.PlayerRemoving:Connect(VehicleServer.RemovePlayer)
RunService.PreSimulation:Connect(VehicleServer.Step)
