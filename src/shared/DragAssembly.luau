-- Movement uses one welded root's CFrame, so external models move as well.
local DragAssembly = {}
export type Snapshot = {
	root: BasePart,
	parts: {BasePart},
	rootOffset: CFrame,
	boxOffset: CFrame,
	boxSize: Vector3,
}

function DragAssembly.capture(target: BasePart | Model, root: BasePart, parts: {BasePart}): Snapshot
	local pivot = target:GetPivot()
	local minimum = Vector3.new(math.huge, math.huge, math.huge)
	local maximum = Vector3.new(-math.huge, -math.huge, -math.huge)
	for _, part in parts do
		local relative = pivot:ToObjectSpace(part.CFrame)
		local half = part.Size * 0.5
		for _, x in {-1, 1} do
			for _, y in {-1, 1} do
				for _, z in {-1, 1} do
					local corner = relative:PointToWorldSpace(Vector3.new(half.X * x, half.Y * y, half.Z * z))
					minimum = minimum:Min(corner)
					maximum = maximum:Max(corner)
				end
			end
		end
	end
	return {
		root = root,
		parts = parts,
		rootOffset = pivot:ToObjectSpace(root.CFrame),
		boxOffset = CFrame.new((minimum + maximum) * 0.5),
		boxSize = maximum - minimum,
	}
end

function DragAssembly.move(assembly: Snapshot, pivot: CFrame)
	assembly.root.CFrame = pivot * assembly.rootOffset
end

function DragAssembly.getPivot(assembly: Snapshot): CFrame
	return assembly.root.CFrame * assembly.rootOffset:Inverse()
end

return table.freeze(DragAssembly)
