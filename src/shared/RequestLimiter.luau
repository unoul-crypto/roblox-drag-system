-- Per-actor token buckets. Keep these on the server and remove departing actors.
local RequestLimiter = {}
RequestLimiter.__index = RequestLimiter

function RequestLimiter.new(clock: (() -> number)?)
	return setmetatable({clock = clock or os.clock, buckets = {}}, RequestLimiter)
end

function RequestLimiter:TryTake(actor: any, rate: number, burst: number): boolean
	if not (rate > 0 and rate < math.huge and burst >= 1 and burst < math.huge) then return false end
	local now = self.clock()
	local bucket = self.buckets[actor]
	if not bucket then
		bucket = {tokens = burst, time = now}
		self.buckets[actor] = bucket
	end
	bucket.tokens = math.min(burst, bucket.tokens + math.max(now - bucket.time, 0) * rate)
	bucket.time = now
	if bucket.tokens < 1 then return false end
	bucket.tokens -= 1
	return true
end

function RequestLimiter:Remove(actor: any)
	self.buckets[actor] = nil
end

return table.freeze(RequestLimiter)
