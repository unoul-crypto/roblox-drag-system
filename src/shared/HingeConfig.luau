return table.freeze({
	TOOL_NAME = "HingeTool",
	TAG_NAME = "can-weld",
	POWER = 0.35, -- 0 disables pulling; 1 uses the limits below in full.
	MAX_FORCE = 12000, -- Absolute force, not multiplied by mass or gravity.
	MAX_TORQUE = 10000,
	MAX_PULL_DISTANCE = 8, -- Also scaled by POWER.
	MAX_SPEED = 4,
	MAX_ANGULAR_SPEED = 2,
	RESPONSIVENESS = 10,
	PULL_TIMEOUT = 8,
	SELECTION_TIMEOUT = 30,
	MAX_USE_DISTANCE = 24,
	MAX_GROUP_PARTS = 128,
	MAX_GROUP_EXTENT = 64,
	MAX_ACTIVE_PULLS = 12,
	CAPTURE_DISTANCE = 0.04,
	CAPTURE_ANGLE = 3, -- Degrees between selected axes before welding is allowed.
	CAPTURE_MAX_SPEED = 0.5, -- Relative speed of the two points, studs/s.
	SETTLE_TIME = 0.15,
	SURFACE_TOLERANCE = 0.15,
	REQUEST_RATE = 4,
	REQUEST_BURST = 3,
	CANCEL_KEY = Enum.KeyCode.Q,
	MARKER_SIZE = 0.3,
	MARKER_COLOR = Color3.fromRGB(95, 220, 180),
})
