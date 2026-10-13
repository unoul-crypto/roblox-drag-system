local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local shared = ReplicatedStorage.Shared
local config = require(shared.VehicleConfig)
local dragConfig = require(shared.DragConfig)
local weldConfig = require(shared.WeldConfig)
local ObjectTargets = require(shared.ObjectTargets)
local ObjectMechanisms = require(shared.ObjectMechanisms)
local InteractionCharacter = require(shared.InteractionCharacter)
local RequestLimiter = require(shared.RequestLimiter)
local VehicleMotion = require(shared.VehicleMotion)
local WeldServer = require(script.Parent.WeldServer)
local ServerOwnership = require(script.Parent.ServerOwnership)
local locks = require(script.Parent.InteractionLocks)

local VehicleServer = {}
type Input = {character: Model, seat: BasePart, forward: boolean, time: number}
local inputs: {[Player]: Input} = {}
local managedMotors: {[HingeConstraint]: boolean} = {}
local limiter = RequestLimiter.new()

local function getDriverSeat(player: Player, seat: any): BasePart?
	if player.Parent ~= Players or not InteractionCharacter.getRoot(player)
		or typeof(seat) ~= "Instance" or not seat:IsDescendantOf(workspace)
		or not (seat:IsA("Seat") or seat:IsA("VehicleSeat"))
		or not CollectionService:HasTag(seat, config.SEAT_TAG) then return nil end
	local humanoid = player.Character:FindFirstChildWhichIsA("Humanoid")
	if humanoid.SeatPart ~= seat or seat.Occupant ~= humanoid or seat.Disabled then return nil end
	return seat
end

function VehicleServer.HandleInput(player: Player, seat: any, forward: any): boolean
	if not limiter:TryTake(player, config.REQUEST_RATE, config.REQUEST_BURST) then return false end
	local driverSeat = getDriverSeat(player, seat)
	if not driverSeat or typeof(forward) ~= "boolean" then inputs[player] = nil; return false end
	inputs[player] = {character = player.Character, seat = driverSeat, forward = forward, time = os.clock()}
	return true
end

function VehicleServer.RemovePlayer(player: Player)
	inputs[player] = nil
	limiter:Remove(player)
end

local function getMotor(wheel: Instance): HingeConstraint?
	if not wheel:IsA("Model") or not ObjectTargets.isSupported(wheel)
		or not ObjectMechanisms.isPreserved(wheel) then return nil end
	local mount = wheel.PrimaryPart
	local motor = wheel:FindFirstChild(config.MOTOR_NAME, true)
	if not mount or not mount:IsDescendantOf(wheel) or not motor or not motor:IsA("HingeConstraint")
		or not motor.Enabled or motor.ActuatorType ~= Enum.ActuatorType.Motor then return nil end
	local a, b = motor.Attachment0, motor.Attachment1
	if not a or not b or not a:IsA("Attachment") or not b:IsA("Attachment")
		or a.Parent ~= mount or not b.Parent or not b.Parent:IsA("BasePart")
		or b.Parent == mount or not b.Parent:IsDescendantOf(wheel) then return nil end
	return motor
end

local function getGroup(seat: BasePart): ({ObjectTargets.Target}?, {BasePart}?)
	local target = ObjectTargets.findTagged(seat, weldConfig.TAG_NAME)
		or ObjectTargets.findTagged(seat, dragConfig.TAG_NAME)
	if not target then return nil, nil end
	local members = WeldServer.GetAssemblyTargets(target)
	local parts = ObjectTargets.getParts(members)
	local occupiedSeats = 0
	for _, part in parts do
		if locks:IsLocked(part) or part.Anchored or not ObjectTargets.isFiniteCFrame(part.CFrame) then return nil, nil end
		if (part:IsA("Seat") or part:IsA("VehicleSeat")) and part.Occupant
			and CollectionService:HasTag(part, config.SEAT_TAG) then occupiedSeats += 1 end
	end
	for _, member in members do if locks:IsLocked(member) then return nil, nil end end
	if occupiedSeats ~= 1 or not ServerOwnership.Claim(parts) then return nil, nil end
	return members, parts
end

-- Recompute from the authoritative weld graph each simulation step so splits stop driving immediately.
function VehicleServer.Step()
	local commands: {[HingeConstraint]: number} = {}
	local wheelMotors: {[Instance]: HingeConstraint} = {}
	for _, wheel in CollectionService:GetTagged(config.WHEEL_TAG) do
		local motor = getMotor(wheel)
		if motor then commands[motor] = 0; wheelMotors[wheel] = motor end
	end
	for player, input in inputs do
		if player.Character ~= input.character or not getDriverSeat(player, input.seat)
			or os.clock() - input.time > config.INPUT_TIMEOUT then
			inputs[player] = nil
			continue
		end
		if not input.forward then continue end
		local members = getGroup(input.seat)
		if not members then continue end
		for _, member in members do
			local motor = wheelMotors[member]
			if motor then
				commands[motor] = VehicleMotion.wheelVelocity(motor.Attachment0.WorldAxis,
					input.seat.CFrame.LookVector, input.seat.CFrame.UpVector, config.WHEEL_ANGULAR_SPEED)
			end
		end
	end
	for motor in managedMotors do
		if commands[motor] == nil and motor.Parent then motor.AngularVelocity = 0; motor.MotorMaxTorque = 0 end
	end
	table.clear(managedMotors)
	for wheel, motor in wheelMotors do
		local busy = locks:IsLocked(wheel)
		for _, part in ObjectTargets.getParts({wheel :: Model}) do
			if locks:IsLocked(part) then busy = true; break end
		end
		local velocity = if busy then 0 else commands[motor]
		motor.AngularVelocity = velocity
		motor.MotorMaxTorque = if busy then 0 elseif velocity == 0 then config.BRAKE_TORQUE else config.MOTOR_MAX_TORQUE
		motor.MotorMaxAcceleration = config.MOTOR_MAX_ACCELERATION
		managedMotors[motor] = true
	end
end

return table.freeze(VehicleServer)
