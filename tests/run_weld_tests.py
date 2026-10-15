"""Run graph, validation, welding and drag-session logic without Studio physics."""
import argparse
from pathlib import Path
import subprocess
import tempfile


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--luau", default="luau")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]

    def source(path: str) -> str:
        return (root / path).read_text(encoding="utf-8-sig")

    sections = ["local mock = (function()", source("tests/RobloxMock.luau"), "end)()",
                "local game, workspace, Instance = mock.game, mock.workspace, mock.Instance",
                "local Vector3, CFrame, Color3, Enum, typeof = mock.Vector3, mock.CFrame, mock.Color3, mock.Enum, mock.typeof",
                "local Vector2 = {new = function(x, y) return {X = x, Y = y} end}",
                "local UDim2 = {new = function(...) return {...} end}",
                "local RaycastParams, OverlapParams = mock.params, mock.params",
                "local PhysicalProperties = {new = function(...) return {...} end}",
                "local warn = function(...) end",
                "mock.clock = 0; local os = {clock = function() return mock.clock end}",
                "local modules = {}",
                "local require = function(name) return assert(modules[name], tostring(name)) end",
                "local script = {Parent = {}}",
                "mock.services.ReplicatedStorage.Shared = {}"]
    for name in ["ConnectionGraph", "TargetLocks", "ValidationRegistry", "WeldConfig",
                 "DragConfig", "DragWeight", "DragCollision", "ObjectTargets", "DragAssembly", "WeldGeometry",
                 "DragManipulation", "DragInputController", "PhysicsTargetMotion", "InteractionCharacter",
                 "InteractionVisibility", "RequestLimiter", "ObjectMechanisms", "VehicleConfig", "VehicleMotion", "FreezeConfig", "JackConfig", "JackMotion", "JackCollision", "ObjectToolClient", "ConnectionToolClient"]:
        sections += [f'modules["{name}"] = (function()', source(f"src/shared/{name}.luau"), "end)()",
                     f'mock.services.ReplicatedStorage.Shared["{name}"] = "{name}"',
                     f'script.Parent["{name}"] = "{name}"']
    # Clone config to test both policies in the same runtime.
    sections += ['modules.ProductionDragConfig = modules.DragConfig',
                 'modules.DragConfig = table.clone(modules.DragConfig)',
                 'modules.DragConfig.BEGIN_REQUEST_BURST = 10000',
                 'modules.DragConfig.UPDATE_REQUEST_BURST = 10000',
                 'modules.WeldConfig = table.clone(modules.WeldConfig)']
    sections += ['modules.FreezeConfig = table.clone(modules.FreezeConfig)']
    sections += ['modules.InteractionLocks = modules.TargetLocks.new()',
                 'script.Parent.InteractionLocks = "InteractionLocks"']
    for name in ["DragServer", "WeldServer", "ServerOwnership", "FreezeServer", "FreezePolicies", "VehicleServer", "VehicleDemo", "JackVisual", "JackServer"]:
        sections += [f'modules["{name}"] = (function()', source(f"src/server/{name}.luau"), "end)()",
                     f'script.Parent["{name}"] = "{name}"']
    sections += ["local function startDragRuntime()", "local script = script.Parent",
                 source("src/server/init.server.luau"), "end",
                 "local function startWeldRuntime()", source("src/server/WeldRuntime.server.luau"), "end",
                 "local function startVehicleRuntime()", source("src/server/VehicleRuntime.server.luau"), "end",
                 "local function startFreezeRuntime()", source("src/server/FreezeRuntime.server.luau"), "end",
                 "local function startJackRuntime()", source("src/server/JackRuntime.server.luau"), "end",
                 "local runTests = (function()", source("tests/Welding.spec.luau"), "end)()",
                 "runTests(mock, modules, startDragRuntime, startWeldRuntime)",
                 "local runExtensions = (function()", source("tests/WeldExtensions.spec.luau"), "end)()",
                 "runExtensions(mock, modules)",
                 "local runControls = (function()", source("tests/DragControls.spec.luau"), "end)()",
                 "runControls(mock, modules)",
                 "local runReach = (function()", source("tests/DragReach.spec.luau"), "end)()",
                 "runReach(mock, modules)",
                 "local runTargetMotion = (function()", source("tests/PhysicsTargetMotion.spec.luau"), "end)()",
                 "runTargetMotion(mock, modules)",
                 "local runSecurity = (function()", source("tests/InteractionSecurity.spec.luau"), "end)()",
                 "runSecurity(mock, modules)",
                 "local runGuards = (function()", source("tests/InteractionGuards.spec.luau"), "end)()",
                 "runGuards(mock, modules)",
                 "local runVehicles = (function()", source("tests/Vehicle.spec.luau"), "end)()",
                 "runVehicles(mock, modules, startVehicleRuntime)",
                 "local runFreeze = (function()", source("tests/Freeze.spec.luau"), "end)()",
                 "runFreeze(mock, modules, startFreezeRuntime)",
                 "local runJack = (function()", source("tests/Jack.spec.luau"), "end)()",
                 "runJack(mock, modules, startJackRuntime)",
                 "local function startJackTool(tool)", "local script = tool.Client",
                 source("src/tools/JackTool/JackTool.client.luau"), "end",
                 "local runToolClients = (function()", source("tests/ToolClients.spec.luau"), "end)()",
                 "runToolClients(mock, modules, startJackTool)"]
    with tempfile.TemporaryDirectory(prefix="weld-tests-") as directory:
        script_path = Path(directory) / "run.luau"
        script_path.write_text("\n".join(sections), encoding="utf-8")
        subprocess.run([args.luau, str(script_path)], check=True)


if __name__ == "__main__":
    main()
