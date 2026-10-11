local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local config = require(ReplicatedStorage.Shared.WeldConfig)
local ObjectTargets = require(ReplicatedStorage.Shared.ObjectTargets)
local WeldServer = require(script.Parent.WeldServer)

local requests: {[Player]: number} = {}
local pending: {[Player]: boolean} = {}

local function equipped(player: Player, name: string, character: Model?): boolean
	local tool = character and character:FindFirstChild(name)
	return player.Parent == Players and player.Character == character
		and tool ~= nil and tool:IsA("Tool") and tool.Enabled
end

local function registerRemote(name: string, toolName: string, unweld: boolean)
	local remote = Instance.new("RemoteFunction")
	remote.Name, remote.Parent = name, ReplicatedStorage
	remote.OnServerInvoke = function(player: Player, hit: any, point: any): (boolean, string)
		local now = os.clock()
		if pending[player] or now - (requests[player] or -math.huge) < config.REQUEST_INTERVAL then
			return false, "Busy"
		end
		requests[player] = now
		local character = player.Character
		if not equipped(player, toolName, character) then return false, "EquipTool" end
		if not ObjectTargets.isSupported(hit) or typeof(point) ~= "Vector3"
			or not ObjectTargets.isFiniteVector(point) then return false, "InvalidTarget" end
		local target = if unweld then hit else ObjectTargets.findTagged(hit, config.TAG_NAME)
		if unweld and not WeldServer.GetWeldTargets(hit) then return false, "InvalidMarker" end
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not target or not root or not root:IsA("BasePart")
			or not ObjectTargets.containsPoint(target, point)
			or (root.Position - point).Magnitude > config.MAX_USE_DISTANCE then return false, "OutOfReach" end
		pending[player] = true
		local guard = function() return equipped(player, toolName, character) end
		local operation = if unweld then WeldServer.UnweldMarker else WeldServer.WeldNearest
		local ok, allowed, reason = pcall(operation, target, player.UserId, guard)
		pending[player] = nil
		if not ok then warn("WeldSystem: request failed:", allowed); return false, "Failed" end
		return allowed, reason
	end
end

registerRemote("WeldNearest", config.TOOL_NAME, false)
registerRemote("UnweldMarker", config.UNWELD_TOOL_NAME, true)
Players.PlayerRemoving:Connect(function(player)
	requests[player] = nil
	-- Keep an in-flight request reserved until its yielding conditions return.
end)
