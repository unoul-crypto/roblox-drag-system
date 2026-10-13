return table.freeze({
	SEAT_TAG = "vehicle-seat", -- Tag the Seat/VehicleSeat itself, not its enclosing model.
	WHEEL_TAG = "vehicle-wheel", -- Tag the prepared Model with PreserveMechanism = true.
	MOTOR_NAME = "WheelMotor",
	WHEEL_ANGULAR_SPEED = 10, -- Radians/s; radius 2 corresponds to about 20 studs/s.
	MOTOR_MAX_TORQUE = 6000,
	MOTOR_MAX_ACCELERATION = 20, -- Radians/s^2, limits how abruptly the motor starts.
	BRAKE_TORQUE = 3000, -- 0 allows coasting when W is released.
	INPUT_SEND_INTERVAL = 0.1,
	INPUT_TIMEOUT = 0.5,
	REQUEST_RATE = 20,
	REQUEST_BURST = 5,
	STUDIO_DEMO_ENABLED = true, -- Creates samples only during Studio Play, not in published games.
})
