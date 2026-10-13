local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local config = require(ReplicatedStorage.Shared.VehicleConfig)

if RunService:IsStudio() and config.STUDIO_DEMO_ENABLED then
	local demo = require(script.Parent.VehicleDemo)
	demo.Spawn(CFrame.new(0, 0, -30), true)
	demo.Spawn(CFrame.new(20, 0, -30), false)
end
