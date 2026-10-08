<#
    Installs Peak Optimizations as a normal Windows app:
      - C:\Program Files\Peak Optimizations\Peak Optimizations.exe (built here from Launcher.cs, with the app icon)
      - a Start menu entry, so it can be found by searching "Peak" in Start / Windows Search
      - an optional desktop shortcut
      - an entry in Settings > Apps so it can be uninstalled
    Running it again updates an existing install. Settings, logs, tweak backups and macros are kept.
#>
param(
    [switch]$Quiet,          # no questions: desktop shortcut yes, don't launch afterwards
    [string]$SandboxRoot     # testing only: install under this folder and HKCU instead of the real locations
)
$ErrorActionPreference = 'Stop'
$AppName = 'Peak Optimizations'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $SandboxRoot) {
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" + $(if ($Quiet) { ' -Quiet' } else { '' })
    try { Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $argList -Verb RunAs }
    catch { Write-Host 'Administrator rights are needed to install Peak Optimizations.' -ForegroundColor Red; Start-Sleep 4 }
    exit
}

function Step([string]$Text) { Write-Host "  - $Text" }
function Ask([string]$Question, [bool]$Default) {
    if ($Quiet) { return $Default }
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    $a = Read-Host "  $Question [$hint]"
    if (-not $a) { return $Default }
    $a -match '^(y|yes)$'
}

$src = $PSScriptRoot
if ($SandboxRoot) {
    $dest = Join-Path $SandboxRoot 'Program Files\Peak Optimizations'
    $startMenuDir = Join-Path $SandboxRoot 'Start Menu\Programs'
    $desktopDir = Join-Path $SandboxRoot 'Desktop'
    $uninstallKey = 'HKCU:\Software\PeakOptimizationsSandbox\Uninstall\PeakOptimizations'
} else {
    $dest = Join-Path $env:ProgramFiles $AppName
    $startMenuDir = [Environment]::GetFolderPath('CommonPrograms')
    $desktopDir = [Environment]::GetFolderPath('CommonDesktopDirectory')
    $uninstallKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PeakOptimizations'
}
$exe = Join-Path $dest "$AppName.exe"
$startMenuLink = Join-Path $startMenuDir "$AppName.lnk"
$desktopLink = Join-Path $desktopDir "$AppName.lnk"
$powershell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

try {
    Write-Host ''
    Write-Host "  $AppName - Setup" -ForegroundColor Magenta
    Write-Host '  ----------------------------------------'
    $files = 'PeakOptimizations.ps1', 'PeakOptimizations.ico', 'Launcher.cs', 'Uninstall.ps1', 'README.md'
    foreach ($f in $files) { if (-not (Test-Path (Join-Path $src $f))) { throw "$f is missing next to Install.ps1. Extract the whole zip and run the installer from there." } }
    $version = if ((Get-Content (Join-Path $src 'PeakOptimizations.ps1') -Raw) -match "\`$AppVersion = '([^']+)'") { $Matches[1] } else { '0.0.0' }
    # The previous install (even one in another folder) is replaced, never left alongside the new one.
    $previous = $null; $previousDir = $null
    if (Test-Path $uninstallKey) { $k = Get-ItemProperty $uninstallKey; $previous = $k.DisplayVersion; $previousDir = $k.InstallLocation }
    if ($previous -and $previous -ne $version) { Write-Host "  Updating $previous  ->  $version   ($dest)" }
    elseif ($previous) { Write-Host "  Reinstalling $version   ($dest)" } else { Write-Host "  Version $version  ->  $dest" }
    Write-Host ''

    # A folder only counts as Peak Optimizations if it has the app in it and isn't a development copy (git repository).
    function Test-PeakFolder([string]$Dir) {
        $Dir -and (Test-Path -LiteralPath (Join-Path $Dir 'PeakOptimizations.ps1')) -and -not (Test-Path -LiteralPath (Join-Path $Dir '.git'))
    }
    function Test-SameFolder([string]$A, [string]$B) {
        if (-not $A -or -not $B -or -not (Test-Path -LiteralPath $A) -or -not (Test-Path -LiteralPath $B)) { return $false }
        (Resolve-Path -LiteralPath $A).Path.TrimEnd('\') -ieq (Resolve-Path -LiteralPath $B).Path.TrimEnd('\')
    }

    # An open copy would keep the old files in use.
    $running = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'PeakOptimizations\.ps1' -and $_.ProcessId -ne $PID })
    if ($running -and -not $SandboxRoot) {
        if (Ask "$AppName is open. Close it to continue?" $true) { $running | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } }
        else { throw 'Setup cancelled - close the app and run setup again.' }
    }

    # Remove the old version completely so no leftover files from it stay behind.
    if ($previousDir -and -not (Test-SameFolder $previousDir $dest) -and -not (Test-SameFolder $previousDir $src) -and (Test-PeakFolder $previousDir)) {
        Step "Removing the old install in $previousDir"
        Remove-Item -LiteralPath $previousDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ((Test-Path -LiteralPath $dest) -and -not (Test-SameFolder $dest $src)) {
        Step $(if ($previous) { "Removing version $previous" } else { 'Clearing the old program folder' })
        Get-ChildItem -LiteralPath $dest -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        $left = @(Get-ChildItem -LiteralPath $dest -Force -ErrorAction SilentlyContinue)
        if ($left) { throw "Some old files are still in use ($(($left | ForEach-Object Name) -join ', ')). Close Peak Optimizations and run setup again." }
    }

    Step 'Copying files'
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    foreach ($f in $files) { Copy-Item -LiteralPath (Join-Path $src $f) -Destination (Join-Path $dest $f) -Force }
    Get-ChildItem -LiteralPath $dest -File | Unblock-File   # drop the "downloaded from the internet" mark

    Step 'Building Peak Optimizations.exe'
    $csc = @("$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe", "$env:SystemRoot\Microsoft.NET\Framework\v4.0.30319\csc.exe") |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    $built = $false
    if ($csc) {
        $manifest = Join-Path $env:TEMP 'PeakOptimizations.manifest'
        @"
<?xml version="1.0" encoding="utf-8"?>
<assembly manifestVersion="1.0" xmlns="urn:schemas-microsoft-com:asm.v1">
  <assemblyIdentity version="1.0.0.0" name="PeakOptimizations.Launcher"/>
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
    <security><requestedPrivileges><requestedExecutionLevel level="requireAdministrator" uiAccess="false"/></requestedPrivileges></security>
  </trustInfo>
</assembly>
"@ | Set-Content -Path $manifest -Encoding UTF8
        if (Test-Path $exe) { Remove-Item -LiteralPath $exe -Force }
        $out = & $csc /nologo /optimize /target:winexe "/out:$exe" "/win32icon:$(Join-Path $dest 'PeakOptimizations.ico')" "/win32manifest:$manifest" (Join-Path $dest 'Launcher.cs') 2>&1
        Remove-Item $manifest -ErrorAction SilentlyContinue
        $built = Test-Path $exe
        if (-not $built) { Write-Host "    Could not build the launcher ($(($out | Out-String).Trim())). Using PowerShell directly instead." -ForegroundColor Yellow }
    } else {
        Write-Host '    .NET Framework compiler not found. Using PowerShell directly instead.' -ForegroundColor Yellow
    }

    function New-Shortcut([string]$Path) {
        New-Item -ItemType Directory -Path (Split-Path $Path) -Force | Out-Null
        $shell = New-Object -ComObject WScript.Shell
        $lnk = $shell.CreateShortcut($Path)
        if ($built) {
            $lnk.TargetPath = $exe
        } else {
            $lnk.TargetPath = $powershell
            $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $dest 'PeakOptimizations.ps1')`""
        }
        $lnk.WorkingDirectory = $dest
        $lnk.IconLocation = "$(Join-Path $dest 'PeakOptimizations.ico'),0"
        $lnk.Description = 'Lightweight Windows optimization utility'
        $lnk.Save()
    }

    Step 'Adding to the Start menu (search "Peak" to find it)'
    New-Shortcut $startMenuLink

    if (Ask 'Add a desktop shortcut?' $true) { Step 'Adding desktop shortcut'; New-Shortcut $desktopLink }
    elseif (Test-Path $desktopLink) { Remove-Item -LiteralPath $desktopLink -Force }

    Step 'Registering in Settings > Apps'
    New-Item -Path $uninstallKey -Force | Out-Null
    $sizeKb = [int]((Get-ChildItem -LiteralPath $dest -File | Measure-Object Length -Sum).Sum / 1KB)
    $values = [ordered]@{
        DisplayName          = $AppName
        DisplayVersion       = $version
        Publisher            = 'rxst0'
        DisplayIcon          = $(if ($built) { "$exe,0" } else { Join-Path $dest 'PeakOptimizations.ico' })
        InstallLocation      = $dest
        InstallDate          = (Get-Date -Format 'yyyyMMdd')
        URLInfoAbout         = 'https://github.com/rxst0/peak-optimizations'
        UninstallString      = "`"$powershell`" -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $dest 'Uninstall.ps1')`""
        QuietUninstallString = "`"$powershell`" -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $dest 'Uninstall.ps1')`" -Quiet"
    }
    foreach ($k in $values.Keys) { New-ItemProperty -Path $uninstallKey -Name $k -Value $values[$k] -PropertyType String -Force | Out-Null }
    foreach ($k in 'NoModify', 'NoRepair') { New-ItemProperty -Path $uninstallKey -Name $k -Value 1 -PropertyType DWord -Force | Out-Null }
    New-ItemProperty -Path $uninstallKey -Name 'EstimatedSize' -Value $sizeKb -PropertyType DWord -Force | Out-Null

    # Keep auto-clean working: point its scheduled task at the new program.
    if (-not $SandboxRoot -and $built) {
        $taskArgs = @{ TaskName = 'Peak Optimizations Auto-Clean'; TaskPath = '\Peak Optimizations\' }
        if (Get-ScheduledTask @taskArgs -ErrorAction SilentlyContinue) {
            Set-ScheduledTask @taskArgs -Action (New-ScheduledTaskAction -Execute $exe -Argument '-AutoClean' -WorkingDirectory $dest) | Out-Null
            Step 'Auto-clean now uses the new version'
        }
    }

    # Older downloads of the app (zips and extracted folders) are deleted so only the new version is left.
    $roots = if ($SandboxRoot) { @(Join-Path $SandboxRoot 'Downloads') }
             else { @((Join-Path $env:USERPROFILE 'Downloads'), [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('MyDocuments')) }
    $old = @(foreach ($root in $roots | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique) {
        Get-ChildItem -LiteralPath $root -Filter 'PeakOptimizations-v*.zip' -File -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Name -match '-v(\d+(\.\d+){1,3})\.zip$' -and [version]$Matches[1] -lt [version]$version) { [pscustomobject]@{ Path = $_.FullName; Version = $Matches[1]; Kind = 'zip' } }
        }
        Get-ChildItem -LiteralPath $root -Filter 'PeakOptimizations.ps1' -File -Recurse -Depth 3 -ErrorAction SilentlyContinue | ForEach-Object {
            $dir = $_.DirectoryName
            if (-not (Test-PeakFolder $dir) -or (Test-SameFolder $dir $src) -or (Test-SameFolder $dir $dest)) { return }
            $v = if ((Get-Content -LiteralPath $_.FullName -Raw) -match "\`$AppVersion = '([^']+)'") { $Matches[1] } else { $null }
            if ($v -and [version]$v -lt [version]$version) { [pscustomobject]@{ Path = $dir; Version = $v; Kind = 'folder' } }
        }
    })
    if ($old) {
        Write-Host ''
        Write-Host '  Older downloads of Peak Optimizations:'
        foreach ($o in $old) { Write-Host "    v$($o.Version)   $($o.Path)" }
        if (Ask 'Delete these old versions?' $true) {
            foreach ($o in $old) {
                Remove-Item -LiteralPath $o.Path -Recurse -Force -ErrorAction SilentlyContinue
                # Also remove the now-empty folder the zip was extracted into (e.g. PeakOptimizations-v1.7.0).
                $parent = Split-Path $o.Path -Parent
                if ($o.Kind -eq 'folder' -and (Split-Path $parent -Leaf) -like 'PeakOptimizations-v*' -and -not (Get-ChildItem -LiteralPath $parent -Force -ErrorAction SilentlyContinue)) {
                    Remove-Item -LiteralPath $parent -Force -ErrorAction SilentlyContinue
                }
            }
            Step "Deleted $($old.Count) old download(s)"
        }
    }

    Write-Host ''
    Write-Host "  $AppName $version is installed$(if ($previous -and $previous -ne $version) { " (replaced $previous)" })." -ForegroundColor Green
    Write-Host '  Open it from Start (type "Peak") or from the desktop shortcut.'
    Write-Host '  Uninstall any time from Settings > Apps.'
    Write-Host ''
    if (-not $SandboxRoot -and (Ask 'Open Peak Optimizations now?' (-not $Quiet))) {
        if ($built) { Start-Process -FilePath $exe }
        else { Start-Process $powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $dest 'PeakOptimizations.ps1')`"" }
    }
} catch {
    Write-Host ''
    Write-Host "  Setup failed: $($_.Exception.Message)" -ForegroundColor Red
    if (-not $Quiet) { Read-Host '  Press Enter to close' | Out-Null }
    exit 1
}
if (-not $Quiet -and -not $SandboxRoot) { Start-Sleep -Seconds 2 }
