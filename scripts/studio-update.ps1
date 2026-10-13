param([string]$RojoPath, [switch]$CopyToClipboard)

$ErrorActionPreference = 'Stop'
$taskProjectRoot = Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot 'build.ps1') -RojoPath $RojoPath

$taskStudioUpdate = Join-Path $taskProjectRoot '.build\studio-update.luau'
& python (Join-Path $PSScriptRoot 'export_studio_update.py') `
    (Join-Path $taskProjectRoot '.build\drag-system.generated.rbxlx') $taskStudioUpdate
if ($LASTEXITCODE -ne 0) { throw 'Studio script export failed.' }

if ($CopyToClipboard) {
    Get-Content -LiteralPath $taskStudioUpdate -Raw -Encoding UTF8 | Set-Clipboard
    Write-Output 'Update copied. Stop Play, paste into Studio Command Bar and press Enter.'
}
