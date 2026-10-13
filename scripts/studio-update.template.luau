-- Run in Studio's Command Bar while Play is stopped. This is not a game Script.
do
	local RunService = game:GetService("RunService")
	assert(RunService:IsStudio() and not RunService:IsRunning(), "Stop Play before updating project scripts")
	local editor = game:GetService("ScriptEditorService")
	local history = game:GetService("ChangeHistoryService")
	local roots = __PROJECT_SCRIPT_ROOTS__
	local function matching(parent, descriptor)
		local found
		for _, child in parent:GetChildren() do
			if child.Name == descriptor.name then
				assert(not found, "Duplicate project object: " .. descriptor.name)
				found = child
			end
		end
		assert(not found or found.ClassName == descriptor.className,
			"Unexpected object class at " .. parent:GetFullName() .. "." .. descriptor.name)
		return found
	end
	local function preflight(parent, descriptor)
		local existing = matching(parent, descriptor)
		if existing then
			for _, child in descriptor.children do preflight(existing, child) end
		end
	end
	for _, root in roots do
		for _, child in root.children do preflight(game:GetService(root.service), child) end
	end
	local scriptsUpdated, objectsAdded = 0, 0
	local function apply(parent, descriptor)
		local object = matching(parent, descriptor)
		if not object then
			object = Instance.new(descriptor.className)
			object.Name, object.Parent = descriptor.name, parent
			objectsAdded += 1
		end
		for property, value in descriptor.properties do
			if property == "Source" then
				if editor:GetEditorSource(object) ~= value then
					editor:UpdateSourceAsync(object, function() return value end)
					scriptsUpdated += 1
				end
			elseif property == "RunContext" then
				local contexts = {[0] = Enum.RunContext.Legacy, [1] = Enum.RunContext.Server, [2] = Enum.RunContext.Client}
			object.RunContext = assert(contexts[value], "Unknown script RunContext")
			else
				object[property] = value
			end
		end
		for _, child in descriptor.children do apply(object, child) end
	end
	history:SetWaypoint("Before Drag System script update")
	local ok, reason = pcall(function()
		for _, root in roots do
			for _, child in root.children do apply(game:GetService(root.service), child) end
		end
	end)
	history:SetWaypoint("Drag System script update")
	assert(ok, "Script update interrupted; undo with Ctrl+Z if needed: " .. tostring(reason))
	print("Drag System: updated " .. scriptsUpdated .. " scripts, added " .. objectsAdded .. " objects. Save the scene, then start Play.")
end
