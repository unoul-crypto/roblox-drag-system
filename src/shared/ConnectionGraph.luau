-- Undirected connections. No Roblox dependencies; all queries return copies.
local ConnectionGraph = {}
ConnectionGraph.__index = ConnectionGraph

type Neighbors = {[any]: boolean}
type State = {adjacency: {[any]: Neighbors}}
export type Graph = typeof(setmetatable({} :: State, ConnectionGraph))

function ConnectionGraph.new(): Graph
	return setmetatable({adjacency = {}}, ConnectionGraph)
end

function ConnectionGraph.HasEdge(self: Graph, a: any, b: any): boolean
	local neighbors = self.adjacency[a]
	return neighbors ~= nil and neighbors[b] == true
end

function ConnectionGraph.AddEdge(self: Graph, a: any, b: any): boolean
	if a == nil or b == nil or a == b or self:HasEdge(a, b) then
		return false
	end
	self.adjacency[a] = self.adjacency[a] or {}
	self.adjacency[b] = self.adjacency[b] or {}
	self.adjacency[a][b] = true
	self.adjacency[b][a] = true
	return true
end

function ConnectionGraph.RemoveEdge(self: Graph, a: any, b: any): boolean
	if not self:HasEdge(a, b) then
		return false
	end
	self.adjacency[a][b] = nil
	self.adjacency[b][a] = nil
	if next(self.adjacency[a]) == nil then self.adjacency[a] = nil end
	if next(self.adjacency[b]) == nil then self.adjacency[b] = nil end
	return true
end

function ConnectionGraph.GetDirect(self: Graph, target: any): {any}
	local result = {}
	for neighbor in self.adjacency[target] or {} do
		table.insert(result, neighbor)
	end
	return result
end

function ConnectionGraph.GetConnected(self: Graph, target: any): {any}
	local visited = {[target] = true}
	local queue = {target}
	local result = {}
	local head = 1
	while head <= #queue do
		local current = queue[head]
		head += 1
		for neighbor in self.adjacency[current] or {} do
			if not visited[neighbor] then
				visited[neighbor] = true
				table.insert(queue, neighbor)
				table.insert(result, neighbor)
			end
		end
	end
	return result
end

function ConnectionGraph.GetIndirect(self: Graph, target: any): {any}
	local result = {}
	for _, neighbor in self:GetConnected(target) do
		if not self:HasEdge(target, neighbor) then
			table.insert(result, neighbor)
		end
	end
	return result
end

return table.freeze(ConnectionGraph)
