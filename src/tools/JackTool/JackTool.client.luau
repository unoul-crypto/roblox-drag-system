local ReplicatedStorage = game:GetService("ReplicatedStorage")
local shared = ReplicatedStorage.Shared
local config = require(shared.JackConfig)
local ObjectTargets = require(shared.ObjectTargets)
local ObjectToolClient = require(shared.ObjectToolClient)

ObjectToolClient(script.Parent, script, {
	remoteName = "PlaceJack",
	hint = "Нажмите на платформу: поставить домкрат. R/F у опоры — высота, X — опустить и убрать",
	color = config.COLOR,
	ignoreFolders = {"WeldConnections"},
	messages = {
		Placed = "Домкрат установлен", Lowering = "Опускаем платформу и убираем домкрат",
		AlreadyPlaced = "Сначала уберите свой предыдущий домкрат", NotOwner = "Это чужой домкрат",
		NoGround = "Под платформой не найден закреплённый пол в пределах " .. config.MAX_SETUP_GAP .. " studs",
		UnevenGround = "Опора под платформой слишком наклонена",
		GroundBlocked = "Под платформой нет места: она пересекается с закреплённой опорой",
		GroundObstructed = "Поиску пола мешает слишком много незакреплённых деталей",
		InvalidTarget = "Выберите свободную платформу с тегом can-drag",
		Busy = "Объект занят — отпустите его и повторите", Limit = "Достигнут лимит домкратов",
		OutOfReach = "Подойдите ближе", NotVisible = "Объект скрыт препятствием",
		NotAlive = "Персонаж должен быть жив", EquipTool = "Возьмите домкрат",
		Denied = "Действие запрещено серверной проверкой",
	},
	hoverTarget = function(hit: Instance?): Instance?
		local current = hit
		while current and current ~= workspace do
			if current:GetAttribute(config.MODEL_ATTRIBUTE) == true then return current end
			current = current.Parent
		end
		return ObjectTargets.findTagged(hit, config.TARGET_TAG)
	end,
})
