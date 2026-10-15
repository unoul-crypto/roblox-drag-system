local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local config = require(ReplicatedStorage.Shared.FreezeConfig)
local InteractionCharacter = require(ReplicatedStorage.Shared.InteractionCharacter)
local RequestLimiter = require(ReplicatedStorage.Shared.RequestLimiter)
local FreezeServer = require(script.Parent.FreezeServer)
require(script.Parent.FreezePolicies).Start()

local limiter = RequestLimiter.new()
local remote = Instance.new("RemoteEvent")
remote.Name, remote.Parent = "UnfreezeOwnModels", ReplicatedStorage
remote.OnServerEvent:Connect(function(player: Player)
	if not limiter:TryTake(player, config.REQUEST_RATE, config.REQUEST_BURST)
		or player.Parent ~= Players or not InteractionCharacter.getRoot(player) then return end
	FreezeServer.UnfreezeAll(player.UserId, "Key")
end)
Players.PlayerRemoving:Connect(function(player) limiter:Remove(player) end)
