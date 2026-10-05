<#
    Removes Peak Optimizations: the program folder, Start menu and desktop shortcuts, and the Settings > Apps entry.
    Settings, logs, tweak backups and macros in C:\ProgramData\PeakOptimizations are kept unless you choose to remove them -
    the tweak backups are what "Undo Selected" uses, so keep them if you might reinstall and undo tweaks later.
#>
param(
    [switch]$Quiet,          # no questions; keeps your data
    [string]$SandboxRoot     # testing only: matches Install.ps1 -SandboxRoot
)
$AppName = 'Peak Optimizations'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $SandboxRoot) {
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" + $(if ($Quiet) { ' -Quiet' } else { '' })
    try { Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $argList -Verb RunAs } catch { }
    exit
}

if ($SandboxRoot) {
    $dest = Join-Path $SandboxRoot 'Program Files\Peak Optimizations'
    $links = (Join-Path $SandboxRoot "Start Menu\Programs\$AppName.lnk"), (Join-Path $SandboxRoot "Desktop\$AppName.lnk")
    $uninstallKey = 'HKCU:\Software\PeakOptimizationsSandbox\Uninstall\PeakOptimizations'
    $dataDir = Join-Path $SandboxRoot 'ProgramData\PeakOptimizations'
} else {
    $dest = Join-Path $env:ProgramFiles $AppName
    $links = (Join-Path ([Environment]::GetFolderPath('CommonPrograms')) "$AppName.lnk"), (Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) "$AppName.lnk")
    $uninstallKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PeakOptimizations'
    $dataDir = Join-Path $env:ProgramData 'PeakOptimizations'
}

Write-Host ''
Write-Host "  $AppName - Uninstall" -ForegroundColor Magenta
Write-Host '  ----------------------------------------'
if (-not $Quiet) {
    $a = Read-Host "  Remove $AppName from this PC? [y/N]"
    if ($a -notmatch '^(y|yes)$') { Write-Host '  Nothing was removed.'; Start-Sleep 2; exit }
}

# Close the app if it's open.
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'PeakOptimizations\.ps1' -and $_.ProcessId -ne $PID } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# Remove the auto-clean scheduled task (and its folder) if it was turned on.
if (-not $SandboxRoot) {
    Unregister-ScheduledTask -TaskName 'Peak Optimizations Auto-Clean' -TaskPath '\Peak Optimizations\' -Confirm:$false -ErrorAction SilentlyContinue
    try { $svc = New-Object -ComObject Schedule.Service; $svc.Connect(); $svc.GetFolder('\').DeleteFolder('Peak Optimizations', 0); Write-Host '  - Removed auto-clean scheduled task' } catch { }
}
foreach ($l in $links) { if (Test-Path -LiteralPath $l) { Remove-Item -LiteralPath $l -Force; Write-Host "  - Removed shortcut $l" } }
if (Test-Path $uninstallKey) { Remove-Item -Path $uninstallKey -Recurse -Force; Write-Host '  - Removed from Settings > Apps' }
Set-Location $env:TEMP   # so the program folder isn't in use
if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue; Write-Host "  - Removed $dest" }

if ((Test-Path $dataDir) -and -not $Quiet) {
    Write-Host ''
    Write-Host "  Your logs, tweak backups and macros are in $dataDir."
    Write-Host '  The tweak backups let you undo tweaks if you reinstall later.'
    $a = Read-Host '  Delete them too? [y/N]'
    if ($a -match '^(y|yes)$') { Remove-Item -LiteralPath $dataDir -Recurse -Force -ErrorAction SilentlyContinue; Write-Host "  - Removed $dataDir" }
}
Write-Host ''
Write-Host "  $AppName has been removed." -ForegroundColor Green
if (-not $Quiet -and -not $SandboxRoot) { Start-Sleep -Seconds 3 }
