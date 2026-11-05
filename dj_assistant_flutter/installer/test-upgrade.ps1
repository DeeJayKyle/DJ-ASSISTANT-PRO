# Tests the installer on a clean Windows machine (CI):
#  1. install DJ Assistant 1.8.1 as a DJ has it, with app data;
#  2. update to the new version exactly as 1.x's auto-updater does
#     (installer /P /UPDATE): 1.x is replaced, data and shortcuts are kept;
#  3. the new app starts and keeps running;
#  4. uninstalling removes the program and never the DJ's data;
#  5. a fresh install works too.
param(
  [Parameter(Mandatory)] [string] $Setup,
  [Parameter(Mandatory)] [string] $Version
)
$ErrorActionPreference = 'Stop'
$Setup = [IO.Path]::GetFullPath($Setup)
$dir = Join-Path $env:LOCALAPPDATA 'DJ Assistant'
$data = Join-Path $env:APPDATA 'com.deejaykyle.djassistant'
$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\DJ Assistant'
$menu = Join-Path ([Environment]::GetFolderPath('Programs')) 'DJ Assistant.lnk'
function Check($ok, $what) { if (-not $ok) { throw "FAILED: $what" } ; Write-Host "ok - $what" }
function Run($exe, $argList) {
  $p = Start-Process $exe -ArgumentList $argList -Wait -PassThru
  if ($p.ExitCode -ne 0) { throw "$exe $argList exited with $($p.ExitCode)" }
}
function Target($lnk) { (New-Object -ComObject WScript.Shell).CreateShortcut($lnk).TargetPath }
function Smoke {
  $p = Start-Process (Join-Path $dir 'dj_assistant.exe') -PassThru
  Start-Sleep -Seconds 20
  $alive = -not $p.HasExited
  $code = if ($alive) { 0 } else { $p.ExitCode }
  if ($alive) { Stop-Process -Id $p.Id -Force; Start-Sleep -Seconds 2 }
  Check $alive "the app starts and keeps running (exit code $code)"
}

# 1. DJ Assistant 1.8.1
$old = Join-Path $env:RUNNER_TEMP 'DJ-Assistant_1.8.1_x64-setup.exe'
Invoke-WebRequest 'https://github.com/DeeJayKyle/DJ-ASSISTANT-PRO/releases/download/v1.8.1/DJ-Assistant_1.8.1_x64-setup.exe' -OutFile $old
Run $old '/S'
$oldExe = (Get-ItemProperty $key).MainBinaryName
Check ((Get-ItemProperty $key).DisplayVersion -eq '1.8.1') '1.8.1 is installed'
Check (Test-Path (Join-Path $dir $oldExe)) "1.8.1 program is in $dir ($oldExe)"
New-Item -ItemType Directory -Force $data | Out-Null
Set-Content (Join-Path $data 'keep-me.txt') 'the DJ library'
if (-not (Test-Path $menu)) { New-Item -ItemType Directory -Force (Split-Path $menu) | Out-Null }

# 2. the auto-update path
Run $Setup '/P /UPDATE'
$reg = Get-ItemProperty $key
Check ($reg.DisplayVersion -eq $Version) "registered as $Version"
Check ($reg.MainBinaryName -eq 'dj_assistant.exe') 'registered program is dj_assistant.exe'
Check (Test-Path (Join-Path $dir 'dj_assistant.exe')) 'new program installed in the same folder'
Check (Test-Path (Join-Path $dir 'flutter_windows.dll')) 'Flutter engine installed'
Check (Test-Path (Join-Path $dir 'vcruntime140.dll')) 'Visual C++ runtime installed next to the app'
Check (-not (Test-Path (Join-Path $dir $oldExe))) '1.8.1 program removed'
Check (Test-Path (Join-Path $data 'keep-me.txt')) 'app data kept'
Check ((Target $menu) -eq (Join-Path $dir 'dj_assistant.exe')) 'Start menu shortcut opens the new version'

# 3. it runs
Smoke

# 4. uninstall keeps the DJ's data
Run (Join-Path $dir 'uninstall.exe') "/S _?=$dir"
Remove-Item (Join-Path $dir 'uninstall.exe') -ErrorAction SilentlyContinue
Check (-not (Test-Path (Join-Path $dir 'dj_assistant.exe'))) 'uninstall removes the program'
Check (-not (Test-Path $key)) 'uninstall removes the registration'
Check (-not (Test-Path $menu)) 'uninstall removes the Start menu shortcut'
Check (Test-Path (Join-Path $data 'keep-me.txt')) 'uninstall keeps the app data'

# 5. fresh install, then installing again over it
Run $Setup '/S'
Check (Test-Path (Join-Path $dir 'dj_assistant.exe')) 'fresh install'
Check (Test-Path $menu) 'fresh install has a Start menu shortcut'
Run $Setup '/P /UPDATE'
Check ((Get-ItemProperty $key).DisplayVersion -eq $Version) 'reinstall over itself'
Smoke
Write-Host 'Installer checks passed.'
