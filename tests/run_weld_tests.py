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
                "local warn = function(...) end",
                "local modules = {}",
                "local require = function(name) return assert(modules[name], tostring(name)) end",
                "local script = {Parent = {}}",
                "mock.services.ReplicatedStorage.Shared = {}"]
    for name in ["ConnectionGraph", "TargetLocks", "ValidationRegistry", "WeldConfig",
                 "DragConfig", "DragWeight", "DragCollision", "ObjectTargets", "DragAssembly", "WeldGeometry",
                 "DragManipulation", "DragInputController", "PhysicsTargetMotion"]:
        sections += [f'modules["{name}"] = (function()', source(f"src/shared/{name}.luau"), "end)()",
                     f'mock.services.ReplicatedStorage.Shared["{name}"] = "{name}"',
                     f'script.Parent["{name}"] = "{name}"']
    # Clone config to test both policies in the same runtime.
    sections += ['modules.DragConfig = table.clone(modules.DragConfig)',
                 'modules.WeldConfig = table.clone(modules.WeldConfig)']
    sections += ['modules.InteractionLocks = modules.TargetLocks.new()',
                 'script.Parent.InteractionLocks = "InteractionLocks"']
    for name in ["DragServer", "WeldServer"]:
        sections += [f'modules["{name}"] = (function()', source(f"src/server/{name}.luau"), "end)()",
                     f'script.Parent["{name}"] = "{name}"']
    sections += ["local function startDragRuntime()", "local script = script.Parent",
                 source("src/server/init.server.luau"), "end",
                 "local function startWeldRuntime()", source("src/server/WeldRuntime.server.luau"), "end",
                 "local runTests = (function()", source("tests/Welding.spec.luau"), "end)()",
                 "runTests(mock, modules, startDragRuntime, startWeldRuntime)",
                 "local runExtensions = (function()", source("tests/WeldExtensions.spec.luau"), "end)()",
                 "runExtensions(mock, modules)",
                 "local runControls = (function()", source("tests/DragControls.spec.luau"), "end)()",
                 "runControls(mock, modules)",
                 "local runReach = (function()", source("tests/DragReach.spec.luau"), "end)()",
                 "runReach(mock, modules)",
                 "local runTargetMotion = (function()", source("tests/PhysicsTargetMotion.spec.luau"), "end)()",
                 "runTargetMotion(mock, modules)"]
    with tempfile.TemporaryDirectory(prefix="weld-tests-") as directory:
        script_path = Path(directory) / "run.luau"
        script_path.write_text("\n".join(sections), encoding="utf-8")
        subprocess.run([args.luau, str(script_path)], check=True)


if __name__ == "__main__":
    main()
