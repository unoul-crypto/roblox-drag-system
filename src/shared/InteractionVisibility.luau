local ObjectTargets = require(script.Parent.ObjectTargets)
local InteractionCharacter = require(script.Parent.InteractionCharacter)
local InteractionVisibility = {}

-- Check server geometry from the character, never a client-provided camera.
-- The selected assembly and weld markers must not occlude their own grab/contact points.
function InteractionVisibility.canSee(player: Player, point: Vector3, targets: {Instance}): boolean
	local root = InteractionCharacter.getRoot(player)
	if not root or not ObjectTargets.isFiniteVector(point) then return false end
	local head = player.Character:FindFirstChild("Head")
	local origin = if head and head:IsA("BasePart") and ObjectTargets.isFiniteCFrame(head.CFrame)
		then head.Position else root.Position
	local direction = point - origin
	if direction.Magnitude < 1e-5 then return true end
	local excluded = table.clone(targets)
	table.insert(excluded, player.Character)
	local markers = workspace:FindFirstChild("WeldConnections")
	if markers then table.insert(excluded, markers) end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = excluded
	params.IgnoreWater = true
	return workspace:Raycast(origin, direction, params) == nil
end

return table.freeze(InteractionVisibility)
