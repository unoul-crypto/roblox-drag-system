local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local config = require(ReplicatedStorage.Shared.VehicleConfig)
local remote = ReplicatedStorage:WaitForChild("VehicleControl") :: RemoteEvent
local player = Players.LocalPlayer
local lastSeat: BasePart? = nil
local lastForward = false
local elapsed = 0
local focused = true
UserInputService.WindowFocusReleased:Connect(function() focused = false end)
UserInputService.WindowFocused:Connect(function() focused = true end)

-- Send only intent. The server discovers the driver's actual seat and connected wheels.
RunService.Heartbeat:Connect(function(dt: number)
	elapsed += dt
	local character = player.Character
	local humanoid = character and character:FindFirstChildWhichIsA("Humanoid")
	local seat = if humanoid and humanoid.Health > 0 then humanoid.SeatPart else nil
	if seat and not CollectionService:HasTag(seat, config.SEAT_TAG) then seat = nil end
	local forward = focused and seat ~= nil and UserInputService:GetFocusedTextBox() == nil
		and UserInputService:IsKeyDown(Enum.KeyCode.W)
	if seat ~= lastSeat or forward ~= lastForward or (seat and elapsed >= config.INPUT_SEND_INTERVAL) then
		if lastSeat and seat ~= lastSeat then remote:FireServer(lastSeat, false) end
		if seat then remote:FireServer(seat, forward) end
		lastSeat, lastForward, elapsed = seat, forward, 0
	end
end)
