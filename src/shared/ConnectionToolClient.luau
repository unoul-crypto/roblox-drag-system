local config = require(script.Parent.WeldConfig)
local ObjectTargets = require(script.Parent.ObjectTargets)
local ObjectToolClient = require(script.Parent.ObjectToolClient)

local messages = {
	Welded = "Объекты сварены", Unwelded = "Соединение удалено",
	InvalidTarget = "Выберите объект с тегом can-weld",
	InvalidMarker = "Выберите шарик сварки", NotWelded = "Соединение уже удалено",
	NoNearbyTarget = "Рядом нет подходящего объекта", TooFar = "Объекты слишком далеко",
	OutOfReach = "Подойдите ближе", AlreadyWelded = "Эти объекты уже сварены",
	Busy = "Объект занят — отпустите его и повторите",
	Denied = "Действие запрещено серверной проверкой", EquipTool = "Возьмите нужный инструмент",
	Failed = "Действие не выполнено",
	NotAlive = "Персонаж должен быть жив", NotVisible = "Объект скрыт препятствием",
}

return function(tool: Tool, ownerScript: LocalScript, unweld: boolean)
	if unweld then return require(script.Parent.UnweldToolClient)(tool, ownerScript, messages) end
	ObjectToolClient(tool, ownerScript, {
		remoteName = "WeldNearest",
		hint = "Нажмите на объект: сварка с ближайшим объектом",
		color = config.MARKER_COLOR,
		ignoreFolders = {"WeldConnections"},
		messages = messages,
		hoverTarget = function(hit: Instance?): Instance?
			return ObjectTargets.findTagged(hit, config.TAG_NAME)
		end,
	})
end
