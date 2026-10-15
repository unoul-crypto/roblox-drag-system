-- Sample geometry is separate from driving/connection logic.
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local config = require(ReplicatedStorage.Shared.VehicleConfig)
local dragConfig = require(ReplicatedStorage.Shared.DragConfig)
local weldConfig = require(ReplicatedStorage.Shared.WeldConfig)
local freezeConfig = require(ReplicatedStorage.Shared.FreezeConfig)
local ObjectMechanisms = require(ReplicatedStorage.Shared.ObjectMechanisms)
local WeldServer = require(script.Parent.WeldServer)
local VehicleDemo = {}

local function part(class: string, name: string, size: Vector3, frame: CFrame, parent: Instance, color: Color3): BasePart
	local value = Instance.new(class) :: BasePart
	value.Name, value.Size, value.CFrame, value.Color = name, size, frame, color
	value.Anchored, value.TopSurface, value.BottomSurface = false, Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
	value.Parent = parent
	return value
end

local function tag(target: Instance)
	CollectionService:AddTag(target, dragConfig.TAG_NAME)
	CollectionService:AddTag(target, weldConfig.TAG_NAME)
	CollectionService:AddTag(target, freezeConfig.TAG_NAME)
	target:SetAttribute(dragConfig.WEIGHT_ATTRIBUTE, 1)
end

function VehicleDemo.Spawn(origin: CFrame, assembled: boolean?): Folder
	local kit = Instance.new("Folder")
	kit.Name, kit.Parent = if assembled then "VehicleDemoReady" else "VehicleDemoParts", workspace
	local platform = part("Part", "Platform", Vector3.new(6, 1, 10), origin * CFrame.new(0, 2.5, 0), kit,
		Color3.fromRGB(65, 125, 180))
	tag(platform)
	local seat = part("Seat", "DriverSeat", Vector3.new(2, 1, 2), origin * CFrame.new(0, 3.5, 0), kit,
		Color3.fromRGB(200, 150, 55)) :: Seat
	tag(seat)
	CollectionService:AddTag(seat, config.SEAT_TAG)
	for _, position in {
		{side = -1, z = -3, name = "FrontLeft"}, {side = 1, z = -3, name = "FrontRight"},
		{side = -1, z = 3, name = "RearLeft"}, {side = 1, z = 3, name = "RearRight"},
	} do
		local side, z, name = position.side, position.z, position.name
		local wheel = Instance.new("Model")
		wheel.Name, wheel.Parent = name, kit
		wheel:SetAttribute(ObjectMechanisms.PRESERVE_ATTRIBUTE, true)
		local mount = part("Part", "Mount", Vector3.new(0.7, 1, 1), origin * CFrame.new(side * 3.4, 2, z), wheel,
			Color3.fromRGB(190, 190, 190))
		local tire = part("Part", "Tire", Vector3.new(1, 4, 4), origin * CFrame.new(side * 4.2, 2, z), wheel,
			Color3.fromRGB(40, 40, 45))
		tire.Shape = Enum.PartType.Cylinder
		tire.CustomPhysicalProperties = PhysicalProperties.new(1, 1, 0, 100, 100)
		wheel.PrimaryPart = mount
		local a, b = Instance.new("Attachment"), Instance.new("Attachment")
		a.Name, a.Position, a.Parent = "Axle", Vector3.new(side * 0.8, 0, 0), mount
		b.Name, b.Parent = "Axle", tire
		local motor = Instance.new("HingeConstraint")
		motor.Name, motor.Attachment0, motor.Attachment1 = config.MOTOR_NAME, a, b
		motor.ActuatorType = Enum.ActuatorType.Motor
		motor.AngularVelocity, motor.MotorMaxTorque = 0, config.BRAKE_TORQUE
		motor.MotorMaxAcceleration = config.MOTOR_MAX_ACCELERATION
		motor.Parent = wheel
		local noCollision = Instance.new("NoCollisionConstraint")
		noCollision.Part0, noCollision.Part1, noCollision.Parent = mount, tire, wheel
		tag(wheel)
		CollectionService:AddTag(wheel, config.WHEEL_TAG)
		if assembled then
			local ok, reason = WeldServer.Weld(platform, wheel)
			assert(ok, "Demo wheel connection failed: " .. reason)
		end
	end
	if assembled then
		local ok, reason = WeldServer.Weld(platform, seat)
		assert(ok, "Demo seat connection failed: " .. reason)
	end
	return kit
end

return table.freeze(VehicleDemo)
