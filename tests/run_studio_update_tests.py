"""Exercise the generated Command Bar update against a minimal Studio adapter."""
import argparse
import importlib.util
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--luau", default="luau")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    spec = importlib.util.spec_from_file_location("exporter", root / "scripts/export_studio_update.py")
    exporter = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(exporter)
    descriptors = exporter.read_roots(root / ".build/drag-system.generated.rbxlx")
    assert {d["service"] for d in descriptors} == set(exporter.ROOTS)
    def sources(nodes):
        result = []
        for node in nodes:
            if "Source" in node["properties"]:
                result.append(node)
            result.extend(sources(node["children"]))
        return result
    scripts = [script for d in descriptors for script in sources(d["children"])]
    assert any(s["name"] == "VehicleDemoRuntime" for s in scripts)
    assert all(s["className"] in exporter.SCRIPT_CLASSES for s in scripts)
    template = (root / "scripts/studio-update.template.luau").read_text(encoding="utf-8-sig")
    payload = exporter.lua(descriptors)
    update = template.replace("__PROJECT_SCRIPT_ROOTS__", payload)
    special = 'Русский текст "quotes" \\u000a \\n\n\r\t\x019'
    adapter = '''
local checks = 0
local function check(value, message) assert(value, message); checks += 1 end
local game, Instance, Enum = mock.game, mock.Instance, mock.Enum
local originalNew = Instance.new
local function fullName(object)
    return if object.Parent then fullName(object.Parent) .. "." .. object.Name else object.Name
end
Instance.new = function(class)
    local object = originalNew(class); object.GetFullName = fullName; return object
end
for _, service in mock.services do service.GetFullName = fullName end
local run = mock.services.RunService
run.IsStudio = function() return true end
run.IsRunning = function() return mock.running == true end
local history = {waypoints = 0}
function history:SetWaypoint() self.waypoints += 1 end
local editor = {updates = 0}
function editor:GetEditorSource(object) return object.Source or "" end
function editor:UpdateSourceAsync(object, callback)
    self.updates += 1; object.Source = callback(object.Source or "")
end
mock.services.ScriptEditorService, mock.services.ChangeHistoryService = editor, history
mock.services.StarterPlayer = Instance.new("StarterPlayer")
mock.services.StarterPack = Instance.new("StarterPack")
local starter = Instance.new("StarterPlayerScripts"); starter.Parent = mock.services.StarterPlayer
local shared = Instance.new("Folder"); shared.Name, shared.Parent = "Shared", mock.services.ReplicatedStorage
local custom = Instance.new("ModuleScript"); custom.Name, custom.Source, custom.Parent = "CustomModule", "return 42", shared
local old = Instance.new("ModuleScript"); old.Name, old.Source, old.Parent = "DragConfig", "return {}", shared
local scenePart = mock.part("ManuallyPlaced", 23); scenePart:SetAttribute("weight", 7)
local function countObjects()
    local count = 0
    for _, name in {"ReplicatedStorage", "ServerScriptService", "StarterPlayer", "StarterPack"} do
        count += #game:GetService(name):GetDescendants()
    end
    return count
end
mock.services.ServerScriptService = Instance.new("ServerScriptService")
'''
    assertions = '''
check(pcall(update), "Command Bar update applies to an existing scene")
local expected = ''' + payload + '''
local function verify(parent, descriptor)
    local object = parent:FindFirstChild(descriptor.name)
    check(object and object.ClassName == descriptor.className, "Project class and name imported")
    for key, value in descriptor.properties do
        if key ~= "RunContext" then check(object[key] == value, "Project source/property round trips exactly") end
    end
    for _, child in descriptor.children do verify(object, child) end
end
for _, service in expected do
    for _, child in service.children do verify(game:GetService(service.service), child) end
end
check(shared.DragConfig == old, "Existing module identity is preserved")
check(custom.Source == "return 42" and custom.Parent == shared, "Unknown user script is preserved")
check(scenePart.Parent == mock.workspace and scenePart.Position.X == 23 and scenePart:GetAttribute("weight") == 7,
    "Studio models, positions and weights are preserved")
check(mock.services.StarterPack.WeldTool.RequiresHandle == false, "Tool metadata is imported")
local updates, objects = editor.updates, countObjects()
check(pcall(update) and editor.updates == updates and countObjects() == objects, "Repeated import is idempotent")
mock.running = true
check(not pcall(update) and editor.updates == updates and countObjects() == objects, "Updates are rejected during Play")
mock.running = false
local bad = shared.DragWeight; bad.Parent = nil
local collision = Instance.new("Folder"); collision.Name, collision.Parent = "DragWeight", shared
objects = countObjects()
check(not pcall(update) and editor.updates == updates and countObjects() == objects,
    "Class collision is detected before changing other scripts")
collision:Destroy(); bad.Parent = shared
local duplicate = Instance.new("ModuleScript"); duplicate.Name, duplicate.Parent = "DragWeight", shared
check(not pcall(update) and editor.updates == updates, "Duplicate names fail before applying updates")
duplicate:Destroy()
check(history.waypoints == 4, "Successful imports delimit undo history")
'''
    with tempfile.TemporaryDirectory(prefix="studio-update-tests-") as directory:
        script = Path(directory) / "run.luau"
        script.write_text("\n".join([
            "local mock = (function()", (root / "tests/RobloxMock.luau").read_text(encoding="utf-8-sig"), "end)()",
            adapter, "local function update()", update, "end", assertions,
            'check(' + exporter.lua(special) + ' == "Русский текст \\"quotes\\" \\\\u000a \\\\n\\n\\r\\t\\0019", "Control characters and literal escapes are preserved")',
            'print("Studio update: " .. checks .. " checks passed (mocked editor)")',
        ]), encoding="utf-8")
        subprocess.run([args.luau, str(script)], check=True)


if __name__ == "__main__":
    main()
