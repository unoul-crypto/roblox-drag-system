local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local JackServer = require(script.Parent.JackServer)

local remote = Instance.new("RemoteFunction")
remote.Name, remote.Parent = "PlaceJack", ReplicatedStorage
remote.OnServerInvoke = JackServer.Place
RunService.PreSimulation:Connect(JackServer.Step)
Players.PlayerRemoving:Connect(JackServer.RemovePlayer)
