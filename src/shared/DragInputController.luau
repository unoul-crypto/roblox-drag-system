-- Owns temporary input/camera locks; target movement is handled by DragManipulation.
local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")
local DragInputController = {}
DragInputController.__index = DragInputController
local SHIFT_ACTION = "DragSystemModifier"
local CONTROL_ACTION = "DragSystemManipulation"
local PRIORITY = Enum.ContextActionPriority.High.Value + 1

local function setZoomBounds(player: Player, minimum: number, maximum: number)
	player.CameraMinZoomDistance = 0
	player.CameraMaxZoomDistance = maximum
	player.CameraMinZoomDistance = minimum
end

function DragInputController.new(player: Player, onWheel: (number) -> ())
	return setmetatable({player = player, onWheel = onWheel, dragging = false, saved = nil}, DragInputController)
end

function DragInputController:IsActive(): boolean
	return self.saved ~= nil
end

function DragInputController:SetActive(active: boolean)
	if active == self:IsActive() then return end
	if not active then
		local saved = self.saved
		self.saved = nil
		if not saved then return end
		saved.camera.CFrame, saved.camera.Focus = saved.frame, saved.focus
		saved.camera.CameraType = saved.cameraType
		setZoomBounds(self.player, saved.zoomMin, saved.zoomMax)
		if saved.humanoid.Parent then
			if saved.humanoid.WalkSpeed == 0 then saved.humanoid.WalkSpeed = saved.walkSpeed end
			if not saved.humanoid.AutoRotate then saved.humanoid.AutoRotate = saved.autoRotate end
		end
		return
	end
	local camera = workspace.CurrentCamera
	local character = self.player.Character
	local humanoid = character and character:FindFirstChildWhichIsA("Humanoid")
	if not self.dragging or not camera or not humanoid then return end
	self.saved = {
		camera = camera, cameraType = camera.CameraType, frame = camera.CFrame, focus = camera.Focus,
		zoomMin = self.player.CameraMinZoomDistance, zoomMax = self.player.CameraMaxZoomDistance,
		humanoid = humanoid, walkSpeed = humanoid.WalkSpeed, autoRotate = humanoid.AutoRotate,
	}
	camera.CameraType = Enum.CameraType.Scriptable
	local zoom = math.max((camera.CFrame.Position - camera.Focus.Position).Magnitude, 0.5)
	setZoomBounds(self.player, zoom, zoom)
	humanoid.WalkSpeed, humanoid.AutoRotate = 0, false
	humanoid:Move(Vector3.zero, false)
	humanoid.Jump = false
end

function DragInputController:SetDragging(dragging: boolean)
	if self.dragging == dragging then return end
	self.dragging = dragging
	if not dragging then
		self:SetActive(false)
		ContextActionService:UnbindAction(SHIFT_ACTION)
		ContextActionService:UnbindAction(CONTROL_ACTION)
		return
	end
	ContextActionService:BindActionAtPriority(SHIFT_ACTION, function(_, state, input)
		if UserInputService:GetFocusedTextBox() then return Enum.ContextActionResult.Pass end
		local other = if input.KeyCode == Enum.KeyCode.LeftShift then Enum.KeyCode.RightShift else Enum.KeyCode.LeftShift
		self:SetActive(state == Enum.UserInputState.Begin or UserInputService:IsKeyDown(other))
		return Enum.ContextActionResult.Sink
	end, false, PRIORITY, Enum.KeyCode.LeftShift, Enum.KeyCode.RightShift)
	ContextActionService:BindActionAtPriority(CONTROL_ACTION, function(_, state, input)
		if not self:IsActive() or UserInputService:GetFocusedTextBox() then return Enum.ContextActionResult.Pass end
		if input.UserInputType == Enum.UserInputType.MouseWheel and state == Enum.UserInputState.Change then
			self.onWheel(input.Position.Z)
		end
		return Enum.ContextActionResult.Sink
	end, false, PRIORITY, Enum.KeyCode.W, Enum.KeyCode.A, Enum.KeyCode.S, Enum.KeyCode.D,
		Enum.KeyCode.Up, Enum.KeyCode.Down, Enum.KeyCode.Left, Enum.KeyCode.Right, Enum.KeyCode.Space,
		Enum.UserInputType.MouseWheel, Enum.UserInputType.MouseButton2)
	self:Update()
end

function DragInputController:Update()
	local shift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
	if self.saved and self.saved.camera ~= workspace.CurrentCamera then self:SetActive(false) end
	self:SetActive(self.dragging and shift and UserInputService:GetFocusedTextBox() == nil)
	local saved = self.saved
	if saved then
		saved.camera.CFrame, saved.camera.Focus = saved.frame, saved.focus
		saved.humanoid:Move(Vector3.zero, false)
		saved.humanoid.Jump = false
	end
end

function DragInputController:GetRotationInput(): (number, number)
	if not self:IsActive() or UserInputService:GetFocusedTextBox() then return 0, 0 end
	local function down(key: Enum.KeyCode): number return if UserInputService:IsKeyDown(key) then 1 else 0 end
	return down(Enum.KeyCode.W) - down(Enum.KeyCode.S), down(Enum.KeyCode.A) - down(Enum.KeyCode.D)
end

function DragInputController:Destroy()
	self:SetDragging(false)
end

return DragInputController
