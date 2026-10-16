"""Export only project scripts/tools from a Rojo build for Studio's Command Bar."""
import argparse
from pathlib import Path
import xml.etree.ElementTree as ET

SCRIPT_CLASSES = {"Script", "LocalScript", "ModuleScript"}
ALLOWED_CLASSES = SCRIPT_CLASSES | {"Folder", "Tool", "StarterPlayerScripts"}
ROOTS = {
    "ReplicatedStorage": {"Shared"},
    "ServerScriptService": {"Server"},
    "StarterPlayer": {"StarterPlayerScripts"},
    "StarterPack": {"WeldTool", "UnweldTool", "JackTool", "HingeTool"},
}
PROPERTIES = {
    "Source", "RunContext", "Disabled", "Enabled", "RequiresHandle", "CanBeDropped",
    "ToolTip", "ManualActivationOnly",
}


def name(item: ET.Element) -> str:
    return item.findtext('Properties/string[@name="Name"]') or ""


def descriptor(item: ET.Element) -> dict:
    class_name = item.attrib["class"]
    if class_name not in ALLOWED_CLASSES:
        raise ValueError(f"Unsupported script-tree class: {class_name}")
    properties = {}
    for prop in item.find("Properties"):
        key = prop.get("name")
        if key not in PROPERTIES:
            continue
        value = prop.text or ""
        if prop.tag in {"string", "ProtectedString"}:
            properties[key] = value
        elif prop.tag == "bool" and value in {"true", "false"}:
            properties[key] = value == "true"
        elif prop.tag == "token" and key == "RunContext" and value in {"0", "1", "2"}:
            properties[key] = int(value)
        else:
            raise ValueError(f"Unsupported property: {key} ({prop.tag})")
    # Source changes must also enable scripts that were disabled in an old Studio copy.
    if class_name in {"Script", "LocalScript"}:
        properties["Disabled"] = False
    return {"name": name(item), "className": class_name, "properties": properties,
            "children": [descriptor(child) for child in item.findall("Item")]}


def read_roots(path: Path) -> list[dict]:
    result = []
    for item in ET.parse(path).getroot().findall("Item"):
        service = name(item)
        if service in ROOTS:
            children = [child for child in item.findall("Item") if name(child) in ROOTS[service]]
            if {name(child) for child in children} != ROOTS[service]:
                raise ValueError(f"Missing project code root in {service}")
            result.append({"service": service, "children": [descriptor(child) for child in children]})
    if {root["service"] for root in result} != ROOTS.keys():
        raise ValueError("Rojo build does not contain all project code services")
    return result


def lua(value) -> str:
    if isinstance(value, str):
        escapes = {"\\": "\\\\", '"': '\\"', "\n": "\\n", "\r": "\\r", "\t": "\\t"}
        quoted = "".join(escapes.get(char, "\\" + f"{ord(char):03d}" if ord(char) < 32 else char)
                         for char in value)
        return '"' + quoted + '"'
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, list):
        return "{" + ",".join(lua(child) for child in value) + "}"
    if isinstance(value, dict):
        return "{" + ",".join(f"[{lua(key)}]={lua(child)}" for key, child in value.items()) + "}"
    raise TypeError(type(value))


def export(build: Path, output: Path) -> None:
    template = Path(__file__).with_name("studio-update.template.luau").read_text(encoding="utf-8-sig")
    output.write_text(template.replace("__PROJECT_SCRIPT_ROOTS__", lua(read_roots(build))), encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    export(args.build, args.output)
    print(f"Studio Command Bar update exported to {args.output.name}")
