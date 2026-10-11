-- Fail-closed checks. Snapshots allow safe registration changes in callbacks.
local ValidationRegistry = {}
ValidationRegistry.__index = ValidationRegistry
type Record = {callback: (...any) -> any}
type State = {records: {Record}, label: string, report: (...any) -> ()}
export type Registry = typeof(setmetatable({} :: State, ValidationRegistry))

function ValidationRegistry.new(label: string, report: ((...any) -> ())?): Registry
	return setmetatable({records = {}, label = label, report = report or print}, ValidationRegistry)
end

function ValidationRegistry.Register(self: Registry, callback: (...any) -> any): () -> ()
	assert(typeof(callback) == "function", "Validator must be a function")
	local record = {callback = callback}
	table.insert(self.records, record)
	local registered = true
	return function()
		if not registered then return end
		registered = false
		local index = table.find(self.records, record)
		if index then table.remove(self.records, index) end
	end
end

function ValidationRegistry.Check(self: Registry, ...: any): boolean
	for _, record in table.clone(self.records) do
		local succeeded, allowed = pcall(record.callback, ...)
		if not succeeded then
			self.report(self.label .. ": validator failed; action denied:", allowed)
			return false
		end
		if allowed ~= true then return false end
	end
	return true
end

return table.freeze(ValidationRegistry)
