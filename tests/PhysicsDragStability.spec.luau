return function(mock, modules)
	local checks = 0
	local function check(value,message) assert(value,message); checks += 1 end
	local function near(a,b) return math.abs(a-b) < 1e-6 end
	local config, collection = modules.DragConfig,mock.services.CollectionService
	local stability, weights = modules.PhysicsDragStability,modules.DragWeight
	local thin, cube = mock.Vector3.new(12,0.05,0.05),mock.Vector3.new(2,2,2)
	local weighted = weights.getPhysicsSettings(0.01,config)
	local normal = stability.getSettings(weighted,cube,config)
	for key, value in weighted do check(normal[key] == value,"Ordinary shapes retain their exact weight settings") end
	local limited = stability.getSettings(weighted,thin,config)
	check(limited.orientationResponsiveness <= config.PHYSICS_STABILITY_ORIENTATION_RESPONSIVENESS
		and limited.maxAngularVelocity <= config.PHYSICS_STABILITY_MAX_ANGULAR_VELOCITY,"Thin light models have bounded angular response and speed")
	check(limited.forceGravityMultiplier <= config.PHYSICS_STABILITY_FORCE_GRAVITY_MULTIPLIER
		and limited.maxVelocity <= config.PHYSICS_STABILITY_MAX_VELOCITY,"Thin models cannot use the original extreme light-body force and speed")
	local previous = weighted.orientationResponsiveness
	for _, aspect in {6,8,12,20,30,100} do
		local settings = stability.getSettings(weighted,mock.Vector3.new(aspect,1,1),config)
		check(settings.orientationResponsiveness <= previous and settings.orientationResponsiveness >= limited.orientationResponsiveness,
			"Shape limits blend monotonically without a response jump at the aspect threshold")
		previous = settings.orientationResponsiveness
	end
	local heavy = weights.getPhysicsSettings(100,config)
	local heavyThin = stability.getSettings(heavy,thin,config)
	for key, value in heavy do check(heavyThin[key] == value,"Stabilization never increases heavy-body limits") end
	local legacy = table.clone(config); legacy.PHYSICS_STABILITY_ENABLED = false
	local old = stability.getSettings(weighted,thin,legacy)
	for key, value in weighted do check(old[key] == value,"Disabling shape limits restores original tuning") end
	check(near(weighted.orientationResponsiveness,weights.getPhysicsSettings(0.01,config).orientationResponsiveness),"Shape tuning does not mutate shared weight results")
	check(stability.mass(0.00001) == 0.00001 and stability.mass(0.02) == 0.02 and stability.mass(0) > 0,
		"Tiny real masses are preserved without dividing by zero")
	local actor = mock.player(502)
	local remotes, run = mock.services.ReplicatedStorage.DragRemotes,mock.services.RunService
	local bar = mock.part("ThinLightBar",0)
	bar.Size,bar.AssemblyMass = thin,0.00001
	bar.CFrame = mock.CFrame.new(0,3,4)*mock.CFrame.fromAxisAngle(mock.Vector3.yAxis,0.7)
	collection:AddTag(bar,"can-drag")
	local localPoint = mock.Vector3.new(5,0.025,0)
	for _, weight in {0.001,0.05,1} do
		bar:SetAttribute("weight",weight)
		local point = bar.CFrame:PointToWorldSpace(localPoint)
		local allowed,_,payload = remotes.BeginDrag.OnServerInvoke(actor,bar,point)
		check(allowed and not payload.clientAuthoritative,"Offset grabs remain server-owned physical drags")
		local rig = bar.DragSystemPhysicsRig
		local position, orientation = rig.DragSystemAlignPosition,rig.DragSystemAlignOrientation
		check(position.ApplyAtCenterOfMass == false and not position.RigidityEnabled and not orientation.RigidityEnabled,
			"Positional force is applied at the clicked point and controllers remain compliant")
		check((position.Attachment0.Position-localPoint).Magnitude < 0.0001 and position.Attachment0 == orientation.Attachment0,
			"A rotated off-center click keeps the original attachment rather than replacing it with the center")
		local settings = stability.getSettings(weights.getPhysicsSettings(weight,config),thin,config)
		check(near(position.MaxForce,bar.AssemblyMass*mock.workspace.Gravity*settings.forceGravityMultiplier)
			and position.Responsiveness == settings.positionResponsiveness and orientation.Responsiveness == settings.orientationResponsiveness,
			"Native controllers use shape-limited settings and the actual tiny mass")
		check(near(position.MaxVelocity,settings.maxVelocity) and near(orientation.MaxAngularVelocity,settings.maxAngularVelocity),
			"Both linear and angular speed limits are installed on the native constraints")
		local original = bar.CFrame
		local desired = mock.CFrame.new(0,1,0)*original*mock.CFrame.fromAxisAngle(mock.Vector3.yAxis,0.1)
		remotes.UpdateDrag.OnServerEvent:Fire(actor,bar,desired,payload.id,true)
		run.PreSimulation:Fire(1/60)
		check(bar.CFrame == original and bar.CanCollide and (position.Attachment0.Position-localPoint).Magnitude < 0.0001,
			"Movement stays physical without changing the CFrame, collisions or grab point")
		check((orientation.CFrame.XVector-desired.XVector).Magnitude < 0.0001,"Edited rotation continues to reach AlignOrientation")
		remotes.EndDrag.OnServerEvent:Fire(actor,bar,payload.id)
		check(not bar:FindFirstChild("DragSystemPhysicsRig") and not modules.InteractionLocks:IsLocked(bar),"Release cleans up the stabilized rig")
	end
	bar:SetAttribute("weight",0.05)
	config.PHYSICS_TARGET_SMOOTHING_ENABLED = false
	local allowed,_,payload = remotes.BeginDrag.OnServerInvoke(actor,bar,bar.CFrame:PointToWorldSpace(localPoint))
	check(allowed and not bar.DragSystemPhysicsRig.DragSystemAlignPosition.ApplyAtCenterOfMass,"Direct-target mode keeps force at the clicked point")
	remotes.EndDrag.OnServerEvent:Fire(actor,bar,payload.id)
	config.PHYSICS_TARGET_SMOOTHING_ENABLED = true
	config.PHYSICS_STABILITY_ENABLED = false
	allowed,_,payload = remotes.BeginDrag.OnServerInvoke(actor,bar,bar.CFrame:PointToWorldSpace(localPoint))
	check(allowed and near(bar.DragSystemPhysicsRig.DragSystemAlignOrientation.Responsiveness,weights.getPhysicsSettings(0.05,config).orientationResponsiveness),
		"The legacy tuning option is applied when creating a native rig")
	remotes.EndDrag.OnServerEvent:Fire(actor,bar,payload.id)
	config.PHYSICS_STABILITY_ENABLED = true
	bar.CFrame = mock.CFrame.new(0,3,4)
	local other = mock.part("OffsetHeavyNeighbor",0)
	other.CFrame,other.Size = bar.CFrame*mock.CFrame.new(-7,0,0),mock.Vector3.new(2,0.05,0.05)
	for _, target in {bar,other} do collection:AddTag(target,"can-weld"); collection:AddTag(target,"can-drag") end
	check(modules.WeldServer.Weld(bar,other),"Create a thin welded group with an off-center root")
	allowed,_,payload = remotes.BeginDrag.OnServerInvoke(actor,bar,bar.CFrame:PointToWorldSpace(localPoint))
	check(allowed and #payload.assembly.parts == 2 and bar.DragSystemPhysicsRig.DragSystemAlignPosition.ApplyAtCenterOfMass == false
		and bar.DragSystemPhysicsRig.DragSystemAlignOrientation.Responsiveness <= config.PHYSICS_STABILITY_ORIENTATION_RESPONSIVENESS,
		"Welded-group bounds also receive shape stabilization without recentering the grab")
	remotes.EndDrag.OnServerEvent:Fire(actor,bar,payload.id)
	modules.WeldServer.Unweld(bar,other)
	bar:Destroy(); other:Destroy()
	print("Physics drag stability: "..checks.." checks passed (settings and geometry; no native force simulation)")
end
