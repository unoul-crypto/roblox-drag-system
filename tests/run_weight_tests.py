"""Run the actual weight module/config with the standalone Luau CLI.

Usage: python tests/run_weight_tests.py --luau path/to/luau.exe
Only the unused marker color needs a Roblox stub; weight code runs unchanged.
"""

import argparse
from pathlib import Path
import subprocess
import tempfile


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--luau", default="luau", help="Path to the Luau CLI")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]

    def source(relative_path: str) -> str:
        return (root / relative_path).read_text(encoding="utf-8-sig")

    script = "\n".join([
        "local config = (function()",
        "local Color3 = {fromRGB = function(...) return {} end}",
        source("src/shared/DragConfig.luau"),
        "end)()",
        "local dragWeight = (function()",
        source("src/shared/DragWeight.luau"),
        "end)()",
        "local runTests = (function()",
        source("tests/DragWeight.spec.luau"),
        "end)()",
        "runTests(dragWeight, config)",
    ])
    with tempfile.TemporaryDirectory(prefix="drag-weight-tests-") as directory:
        test_file = Path(directory) / "run.luau"
        test_file.write_text(script, encoding="utf-8")
        subprocess.run([args.luau, str(test_file)], check=True)


if __name__ == "__main__":
    main()
