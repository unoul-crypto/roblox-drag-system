return table.freeze({
	TOOL_NAME = "JackTool",
	TARGET_TAG = "can-drag",
	MODEL_ATTRIBUTE = "IsVehicleJack",
	MAX_USE_DISTANCE = 16,
	DEFAULT_LIFT = 3, -- Added to the platform's current clearance above the ground.
	MAX_HEIGHT = 8, -- Platform underside above the ground, in studs.
	HEIGHT_STEP = 0.5,
	LIFT_SPEED = 1.5, -- Studs/second, in either direction.
	RESPONSE_TIME = 0.2,
	MAX_SETUP_GAP = 6,
	GROUND_CONTACT_TOLERANCE = 0.15, -- Accept small physics penetration at rest.
	MAX_GROUND_RAY_HITS = 32, -- Bound retries while skipping loose parts above the floor.
	MIN_GROUND_NORMAL_Y = 0.95,
	COLLISION_PADDING = 0.03,
	MAX_GROUP_PARTS = 128,
	MAX_GROUP_EXTENT = 64,
	MAX_ACTIVE_JACKS = 20,
	REQUEST_RATE = 4,
	REQUEST_BURST = 3,
	RAISE_KEY = Enum.KeyCode.R,
	LOWER_KEY = Enum.KeyCode.F,
	REMOVE_KEY = Enum.KeyCode.X,
	COLOR = Color3.fromRGB(225, 155, 40),
})
