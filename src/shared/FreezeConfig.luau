return table.freeze({
	TAG_NAME = "can-freeze",
	IGNORE_COLLISION_TAG = "not-unfreeze",
	REQUIRE_ALL_MEMBERS_FREEZABLE = true,
	MAX_FROZEN_MODELS = 3, -- Connected groups count as one. 0 disables player freezing.
	UNFREEZE_DISTANCE = 48, -- Studs to the nearest part bounds; 0 disables distance removal.
	UNFREEZE_KEY = Enum.KeyCode.E,
	UNFREEZE_ON_COLLISION = true,
	CHECK_INTERVAL = 0.1,
	COLLISION_GRACE_TIME = 0.1,
	COLLISION_TOLERANCE = 0.02,
	REQUEST_RATE = 4,
	REQUEST_BURST = 2,
})
