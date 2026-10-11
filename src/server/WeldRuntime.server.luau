local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local config = require(ReplicatedStorage.Shared.WeldConfig)
local ObjectTargets = require(ReplicatedStorage.Shared.ObjectTargets)
local WeldServer = require(script.Parent.WeldServer)

local remote = Instance.new("RemoteFunction")
remote.Name, remote.Parent = "WeldNearest", ReplicatedStorage
local requests: {[Player]: number} = {}
local pending: {[Player]: boolean} = {}

remote.OnServerInvoke = function(player: Player, hit: any, point: any): (boolean, string)
	local now = os.clock()
	if pending[player] or now - (requests[player] or -math.huge) < config.REQUEST_INTERVAL then
		return false, "Busy"
	end
	requests[player] = now
	local character = player.Character
	local tool = character and character:FindFirstChild(config.TOOL_NAME)
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not tool or not tool:IsA("Tool") or not tool.Enabled then return false, "EquipTool" end
	if not ObjectTargets.isSupported(hit) or typeof(point) ~= "Vector3"
		or not ObjectTargets.isFiniteVector(point) then return false, "InvalidTarget" end
	local target = ObjectTargets.findTagged(hit, config.TAG_NAME)
	if not target or not root or not root:IsA("BasePart")
		or not ObjectTargets.containsPoint(target, point)
		or (root.Position - point).Magnitude > config.MAX_USE_DISTANCE then return false, "OutOfReach" end
	pending[player] = true
	local ok, allowed, reason = pcall(WeldServer.WeldNearest, target, player.UserId)
	pending[player] = nil
	if not ok then warn("WeldSystem: request failed:", allowed); return false, "Failed" end
	return allowed, reason
end

Players.PlayerRemoving:Connect(function(player)
	requests[player], pending[player] = nil, nil
end)
