-- Atomic reservations shared by dragging and welding, including part keys.
local TargetLocks = {}
TargetLocks.__index = TargetLocks
type State = {owners: {[any]: {any}}}
export type Locks = typeof(setmetatable({} :: State, TargetLocks))

function TargetLocks.new(): Locks
	return setmetatable({owners = {}}, TargetLocks)
end

function TargetLocks.IsLocked(self: Locks, key: any): boolean
	return self.owners[key] ~= nil
end

function TargetLocks.TryAcquire(self: Locks, keys: {any}): (() -> ())?
	for _, key in keys do
		if self:IsLocked(key) then return nil end
	end
	local token = table.clone(keys)
	for _, key in token do self.owners[key] = token end
	local released = false
	return function()
		if released then return end
		released = true
		for _, key in token do
			if self.owners[key] == token then self.owners[key] = nil end
		end
	end
end

return table.freeze(TargetLocks)
