local ObjectTargets = require(script.Parent.ObjectTargets)
local InteractionCharacter = {}

-- All server reach checks must use a real, finite character transform.
function InteractionCharacter.getRoot(player: Player): BasePart?
	local character = player.Character
	if not character or not character:IsDescendantOf(workspace) then return nil end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") or not ObjectTargets.isFiniteCFrame(root.CFrame) then return nil end
	return root
end

return table.freeze(InteractionCharacter)
