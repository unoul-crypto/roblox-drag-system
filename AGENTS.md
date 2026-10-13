# Project workflow

- `drag-system.rbxlx` is the user's saved Roblox Studio scene. Preserve it, including manually placed models, tags and attributes. Never use it as a build output or overwrite it with generated content.
- Run validation builds through `scripts/build.ps1`. Its output is `.build/drag-system.generated.rbxlx`. Generated builds contain the file project, not the user's Studio-only models.
- Sync code into the existing Studio scene with `rojo serve`. Keep `Workspace.$ignoreUnknownInstances = true` in `default.project.json`.
- Do not modify, replace or delete other existing `.rbxl`/`.rbxlx` scene files unless the user explicitly requests it.
