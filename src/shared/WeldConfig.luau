return table.freeze({
	TAG_NAME = "can-weld",
	TOOL_NAME = "WeldTool",
	UNWELD_TOOL_NAME = "UnweldTool",
	MARKER_ATTRIBUTE = "WeldMarker",
	MAX_WELD_DISTANCE = 1, -- Distance between surfaces, in studs.
	MAX_USE_DISTANCE = 24,
	REQUEST_INTERVAL = 0.25,
	MARKER_SIZE = 0.35,
	MARKER_COLOR = Color3.fromRGB(255, 170, 40),
	UNWELD_ICON_SIZE = 36, -- Screen pixels.
	UNWELD_ICON_GAP = 6,
	UNWELD_REFRESH_INTERVAL = 0.15,
})
