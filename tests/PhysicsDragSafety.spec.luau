return function(mock, modules)
	local checks = 0
	local function check(value,message) assert(value,message); checks += 1 end
	local safety, config = modules.PhysicsDragStability,modules.DragConfig
	local settings = modules.DragWeight.getPhysicsSettings(0.01,config)
	for _, mass in {math.huge,-math.huge,0/0,0,-1,1e308,1e35} do
		check(not safety.limits(mass,196.2,6,settings),"Invalid or overflowing mass cannot become a native force limit")
	end
	check(safety.limits(0.00001,196.2,6,settings) ~= nil,"Valid tiny masses still produce finite native force limits")
	local actor = mock.player(503)
	local remotes, run = mock.services.ReplicatedStorage.DragRemotes,mock.services.RunService
	local function fixture()
		local model = mock.Instance.new("Model"); model.Name,model.Parent = "PhysicsSafetyFixture",mock.workspace
		local root = mock.part("Root",0,model); root.Size,root.CFrame = mock.Vector3.new(12,0.05,0.05),mock.CFrame.new(0,3,4)
		local tip = mock.part("Tip",0,model); tip.Size,tip.CFrame = mock.Vector3.new(1,0.05,0.05),mock.CFrame.new(6.5,3,4)
		root.Anchored,tip.Anchored,root.AssemblyMass = true,true,0.02
		model.PrimaryPart = root
		model:SetAttribute("weight",0.01); model:SetAttribute("DragCollisionMode","NoClip")
		mock.services.CollectionService:AddTag(model,"can-drag")
		return model,root,tip
	end
	local function begin(model,root) return remotes.BeginDrag.OnServerInvoke(actor,model,root.Position) end
	local function restored(model,root,tip)
		return model.Parent == mock.workspace and root.Parent == model and tip.Parent == model and model.PrimaryPart == root
			and root.Anchored and tip.Anchored and root.CanCollide and tip.CanCollide
			and not model:FindFirstChild("DragSystemTemporaryRig") and not model:FindFirstChild("DragSystemPhysicsRig")
			and not root:FindFirstChild("DragSystemGrabAttachment") and not root:FindFirstChild("DragSystemForceAttachment")
			and not modules.InteractionLocks:IsLocked(model)
	end
	for _, mass in {math.huge,0/0,0,-1,1e308} do
		local model,root,tip = fixture(); root.AssemblyMass = mass
		local allowed = begin(model,root)
		local rig = model.DragSystemPhysicsRig
		check(allowed and rig and not rig.DragSystemAlignPosition.Enabled and not rig.DragSystemAlignOrientation.Enabled,
			"Unsettled mass leaves both controllers disabled at startup")
		check(rig.DragSystemAlignPosition.MaxForce == 0 and rig.DragSystemAlignOrientation.MaxTorque == 0,
			"Pending controllers contain zero force instead of infinity or NaN")
		for _ = 1,40 do run.PreSimulation:Fire(1/60) end
		check(restored(model,root,tip),"Invalid startup times out without removing the model or leaving authored properties changed")
		model:Destroy()
	end
	local model,root,tip = fixture(); root.AssemblyMass = math.huge
	local allowed,_,payload = begin(model,root)
	remotes.UpdateDrag.OnServerEvent:Fire(actor,model,mock.CFrame.new(0,4,4),payload.id,true)
	check(allowed and not model.DragSystemPhysicsRig.DragSystemAlignPosition.Enabled,"Packets cannot activate an uninitialized rig")
	root.AssemblyMass = 0.02
	run.PreSimulation:Fire(1/60)
	check(model.DragSystemPhysicsRig.DragSystemAlignPosition.Enabled and model.DragSystemPhysicsRig.DragSystemAlignOrientation.Enabled,
		"Startup resumes once the assembly publishes valid physical data")
	root.AssemblyMass = math.huge; run.PreSimulation:Fire(1/60)
	check(restored(model,root,tip),"Invalid mass during an active drag cancels before another native force update")
	model:Destroy()
	for _, center in {mock.Vector3.new(0/0,0,0),mock.Vector3.new(math.huge,0,0),mock.Vector3.new(1000,0,0)} do
		model,root,tip = fixture(); root.AssemblyCenterOfMass = center
		allowed,_,payload = begin(model,root)
		check(allowed and not model.DragSystemPhysicsRig.DragSystemAlignPosition.Enabled,"Invalid or stale centers cannot enable an offset force")
		root.AssemblyCenterOfMass = root.Position; run.PreSimulation:Fire(1/60)
		check(model.DragSystemPhysicsRig.DragSystemAlignPosition.Enabled,"A valid center recovers the waiting drag")
		remotes.EndDrag.OnServerEvent:Fire(actor,model,payload.id)
		check(restored(model,root,tip),"Recovered drag still restores the original parts on release")
		model:Destroy()
	end
	for _, class in {"WeldConstraint","Attachment","AlignPosition","AlignOrientation"} do
		model,root,tip = fixture(); mock.failNextClass = class
		check(not begin(model,root),"Injected rig-construction errors deny grabbing")
		check(restored(model,root,tip),"Partial construction rolls back every owned helper, anchor, collision state and lock")
		model:Destroy()
	end
	model,root,tip = fixture(); allowed,_,payload = begin(model,root)
	check(allowed,"Valid startup still succeeds immediately")
	root.AssemblyCenterOfMass = mock.Vector3.new(0/0,0,0); run.PreSimulation:Fire(1/60)
	check(restored(model,root,tip),"A corrupted active center cancels without removing any authored part")
	model:Destroy()
	model,root,tip = fixture()
	root.CFrame = root.CFrame*mock.CFrame.fromAxisAngle(mock.Vector3.new(0.3,0.4,0.5),0.7)
	allowed,_,payload = begin(model,root)
	local rig = model.DragSystemPhysicsRig
	check(allowed and rig,"A rotated thin assembly can be grabbed")
	local floatBuffer = buffer.create(4)
	for _ = 1,600 do
		local matrix = table.clone(rig.DragSystemAlignOrientation.CFrame.matrix)
		for i,v in matrix do buffer.writef32(floatBuffer,0,v); matrix[i] = buffer.readf32(floatBuffer,0) end
		rig.DragSystemAlignOrientation.CFrame = mock.CFrame.newWithMatrix(mock.Vector3.zero,matrix)
		run.PreSimulation:Fire(1/60)
	end
	check(model:FindFirstChild("DragSystemPhysicsRig") == rig and rig.DragSystemAlignOrientation.Enabled
		and modules.ObjectTargets.isFiniteCFrame(rig.DragSystemAlignOrientation.CFrame),
		"Ordinary float32 roundoff cannot cancel a settled physical grab")
	rig.DragSystemAlignOrientation.CFrame = mock.CFrame.newWithMatrix(mock.Vector3.zero,{0/0,0,0,0,1,0,0,0,1})
	run.PreSimulation:Fire(1/60)
	check(restored(model,root,tip),"Actually corrupt rotation still disables forces and safely releases the assembly")
	model:Destroy()
	print("Physics drag safety: "..checks.." checks passed (invalid data, deferred startup and rollback; mocked engine)")
end
