param([string]$RojoPath)

$ErrorActionPreference = 'Stop'
$taskProjectRoot = Split-Path -Parent $PSScriptRoot

if (-not $RojoPath) {
    $taskRojoCommand = Get-Command rojo -ErrorAction SilentlyContinue
    if ($taskRojoCommand) {
        $RojoPath = $taskRojoCommand.Source
    } else {
        $RojoPath = Join-Path $env:USERPROFILE 'Documents\applications\rojo.exe'
        if (-not (Test-Path -LiteralPath $RojoPath -PathType Leaf)) {
            throw 'Rojo was not found. Pass -RojoPath with the path to rojo.exe.'
        }
    }
}

$taskBuildDirectory = Join-Path $taskProjectRoot '.build'
New-Item -ItemType Directory -Path $taskBuildDirectory -Force | Out-Null
$taskBuildOutput = Join-Path $taskBuildDirectory 'drag-system.generated.rbxlx'
$taskProjectFile = Join-Path $taskProjectRoot 'default.project.json'

# The output is fixed and separate from the user's saved Studio scene.
& $RojoPath build $taskProjectFile -o $taskBuildOutput
if ($LASTEXITCODE -ne 0) {
    throw "Rojo build failed with exit code $LASTEXITCODE."
}
