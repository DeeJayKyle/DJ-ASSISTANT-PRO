# Builds the DJ Assistant installer from the Flutter release build.
#   pwsh installer/build.ps1 -Version 2.0.0 -Out release/DJ-Assistant_2.0.0_x64-setup.exe
# Run `flutter build windows --release` first.
param(
  [Parameter(Mandatory)] [string] $Version,
  [Parameter(Mandatory)] [string] $Out
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$rel = Join-Path $root 'build\windows\x64\runner\Release'
if (-not (Test-Path "$rel\dj_assistant.exe")) { throw "No release build in $rel - run flutter build windows --release first." }

# The Visual C++ runtime, next to the app, so it starts on PCs that never
# installed it (Microsoft allows this app-local copy).
foreach ($dll in 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll') {
  if (-not (Test-Path "$rel\$dll")) { Copy-Item (Join-Path $env:WINDIR "System32\$dll") $rel }
}

$nsis = (Get-Command makensis -ErrorAction SilentlyContinue).Source
if (-not $nsis) { $nsis = "${env:ProgramFiles(x86)}\NSIS\makensis.exe" }
if (-not (Test-Path $nsis)) {
  choco install nsis -y --no-progress | Out-Null
  $nsis = "${env:ProgramFiles(x86)}\NSIS\makensis.exe"
}
$outFull = [IO.Path]::GetFullPath($Out)
New-Item -ItemType Directory -Force (Split-Path -Parent $outFull) | Out-Null
& $nsis /V2 "/DVERSION=$Version" "/DSRC=$rel" "/DICON=$root\windows\runner\resources\app_icon.ico" "/DOUT=$outFull" "$PSScriptRoot\dj_assistant.nsi"
if ($LASTEXITCODE -ne 0) { throw "makensis failed ($LASTEXITCODE)" }
Write-Host "Built $outFull ($([math]::Round((Get-Item $outFull).Length / 1MB, 1)) MB)"
