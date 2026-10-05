<#
    Peak Optimizations - a lightweight Windows optimization utility.
    Single file, no dependencies: Windows PowerShell 5.1 + WPF (both ship with Windows 10/11).
    Inspired by Chris Titus Tech's WinUtil (Install / Tweaks / Config / Updates).

    Every registry/service change made by a tweak is backed up to
    %ProgramData%\PeakOptimizations\backup.json first, so "Undo Selected" restores the real original value.
#>
param(
    # Builds the whole UI and exits without showing it (used to validate the script).
    [switch]$SelfTest
)

#region Bootstrap ---------------------------------------------------------------
$AppName = 'Peak Optimizations'
$AppVersion = '1.4.0'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $SelfTest -and (-not $isAdmin -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA')) {
    # Relaunch elevated in Windows PowerShell 5.1 (STA, needed for WPF and Checkpoint-Computer).
    $argList = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`""
    try { Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $argList -Verb RunAs }
    catch { Write-Host 'Administrator rights are required to run Peak Optimizations.' -ForegroundColor Red; Start-Sleep 3 }
    exit
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$DataDir = Join-Path $env:ProgramData 'PeakOptimizations'
New-Item -ItemType Directory -Path $DataDir -Force | Out-Null

$sync = [hashtable]::Synchronized(@{
    Log     = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    DataDir = $DataDir
    Busy    = $false
    Job     = $null
    Result  = $null
    Backup  = @{}
})

# Load the undo backup (first-seen original values).
$backupFile = Join-Path $DataDir 'backup.json'
if (Test-Path $backupFile) {
    try {
        (Get-Content $backupFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $sync.Backup[$_.Name] = $_.Value }
    } catch { }
}
#endregion

#region Helpers (shared by the UI thread and background jobs) --------------------
$Helpers = {
    function Write-Log {
        param([string]$Message, [string]$Level = 'INFO')
        $prefix = if ($Level -eq 'INFO') { '' } else { "${Level}: " }
        $line = '[{0}] {1}{2}' -f (Get-Date -Format 'HH:mm:ss'), $prefix, $Message
        $sync.Log.Enqueue($line)
        try { Add-Content -Path (Join-Path $sync.DataDir 'peak.log') -Value $line -Encoding UTF8 } catch { }
    }

    function Save-Backup {
        try { $sync.Backup | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $sync.DataDir 'backup.json') -Encoding UTF8 }
        catch { Write-Log "Could not save backup: $($_.Exception.Message)" 'WARN' }
    }

    function Get-RegValue {
        param([string]$Path, [string]$Name)
        try { (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name } catch { $null }
    }

    function Set-RegValue {
        param([string]$Path, [string]$Name, $Value, [string]$Type)
        if (-not $Type) { $Type = 'DWord' }
        if ($Value -is [string] -and $Value -eq '<Remove>') {
            if (Test-Path $Path) { Remove-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue }
            return
        }
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
    }

    function Backup-RegValue {
        param([string]$Path, [string]$Name)
        $key = "reg|$Path|$Name"
        if ($sync.Backup.ContainsKey($key)) { return }
        $entry = @{ Exists = $false; Value = $null; Type = 'DWord' }
        if (Test-Path $Path) {
            $item = Get-Item -Path $Path
            if ($item.GetValueNames() -contains $Name) {
                $entry.Exists = $true
                $entry.Value = $item.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
                $entry.Type = $item.GetValueKind($Name).ToString()
            }
        }
        $sync.Backup[$key] = $entry
    }

    function Restore-RegValue {
        param([string]$Path, [string]$Name)
        $key = "reg|$Path|$Name"
        if (-not $sync.Backup.ContainsKey($key)) {
            # No recorded original: removing the value returns Windows to its default behaviour.
            Set-RegValue -Path $Path -Name $Name -Value '<Remove>'
            return
        }
        $b = $sync.Backup[$key]
        if ($b.Exists) {
            $v = $b.Value
            if ($b.Type -eq 'Binary') { $v = [byte[]]$v } elseif ($b.Type -eq 'MultiString') { $v = [string[]]$v }
            Set-RegValue -Path $Path -Name $Name -Value $v -Type $b.Type
        } else {
            Set-RegValue -Path $Path -Name $Name -Value '<Remove>'
        }
        $sync.Backup.Remove($key)
    }

    function Get-ServiceStartup {
        param([string]$Name)
        $p = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
        if (-not (Test-Path $p)) { return $null }
        switch (Get-RegValue $p 'Start') {
            2 { if ((Get-RegValue $p 'DelayedAutostart') -eq 1) { 'AutomaticDelayedStart' } else { 'Automatic' } }
            3 { 'Manual' }
            4 { 'Disabled' }
            default { $null }
        }
    }

    function Set-ServiceStartup {
        param([string]$Name, [string]$Startup)
        $map = @{ Automatic = 'auto'; AutomaticDelayedStart = 'delayed-auto'; Manual = 'demand'; Disabled = 'disabled' }
        $out = & sc.exe config $Name start= $map[$Startup] 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log ("  Service ${Name}: could not set {0} ({1})" -f $Startup, (($out | Out-String) -replace '\s+', ' ').Trim()) 'WARN'
        } elseif ($Startup -eq 'Disabled') {
            Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
        }
    }

    function Set-TaskEnabled {
        param([string]$Task, [bool]$Enabled)
        $flag = if ($Enabled) { '/Enable' } else { '/Disable' }
        $null = & schtasks.exe /Change /TN $Task $flag 2>&1
    }

    function Remove-AppxEverywhere {
        param([string[]]$Names)
        $provisioned = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
        foreach ($n in $Names) {
            $pkgs = Get-AppxPackage -AllUsers -Name $n -ErrorAction SilentlyContinue
            $prov = $provisioned | Where-Object DisplayName -like $n
            if (-not $pkgs -and -not $prov) { continue }
            Write-Log "  Removing $n"
            $pkgs | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
            $prov | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null
        }
    }

    # Runs a console tool and logs its meaningful output (drops progress bars/spinners).
    function Invoke-Exe {
        param([string]$FilePath, [string[]]$ArgumentList, [switch]$Quiet)
        $out = & $FilePath @ArgumentList 2>&1
        $code = $LASTEXITCODE
        $lines = foreach ($l in $out) {
            $s = (("$l" -split "`r")[-1] -replace "`0", '').Trim()
            if ($s -and $s -match '[A-Za-z]{2}' -and $s -notmatch '[â–€-â–Ÿ]' -and $s -notmatch '\[=+|\d+(\.\d+)?%') { $s }
        }
        if (-not $Quiet) { foreach ($s in $lines) { Write-Log "  $s" } }
        [pscustomobject]@{ Code = $code; Lines = @($lines) }
    }

    function Test-Winget {
        if (Get-Command winget.exe -ErrorAction SilentlyContinue) { return $true }
        Write-Log 'winget was not found. Install "App Installer" from the Microsoft Store, then try again.' 'ERROR'
        $false
    }

    function Invoke-Tweak {
        param($Tweak, [switch]$Undo)
        if ($Undo -and $Tweak.NoUndo) { Write-Log "Skip undo: $($Tweak.Name) - $($Tweak.NoUndo)"; return }
        Write-Log ('{0} {1}' -f $(if ($Undo) { 'Undo:' } else { 'Apply:' }), $Tweak.Name)

        foreach ($r in @($Tweak.Registry)) {
            if (-not $r) { continue }
            try {
                if ($Undo) { Restore-RegValue -Path $r.Path -Name $r.Name }
                else {
                    Backup-RegValue -Path $r.Path -Name $r.Name
                    Set-RegValue -Path $r.Path -Name $r.Name -Value $r.Value -Type $r.Type
                }
            } catch { Write-Log "  $($r.Path)\$($r.Name): $($_.Exception.Message)" 'WARN' }
        }

        foreach ($s in @($Tweak.Services)) {
            if (-not $s) { continue }
            $current = Get-ServiceStartup $s.Name
            if (-not $current) { continue }
            $key = "svc|$($s.Name)"
            if ($Undo) {
                if ($sync.Backup.ContainsKey($key)) { Set-ServiceStartup $s.Name $sync.Backup[$key]; $sync.Backup.Remove($key) }
            } else {
                if (-not $sync.Backup.ContainsKey($key)) { $sync.Backup[$key] = $current }
                if ($current -ne $s.Startup) { Set-ServiceStartup $s.Name $s.Startup }
            }
        }

        foreach ($t in @($Tweak.Tasks)) { if ($t) { Set-TaskEnabled -Task $t -Enabled ([bool]$Undo) } }

        $code = if ($Undo) { $Tweak.Undo } else { $Tweak.Script }
        if ($code) {
            # Recreate the script block inside this runspace (script blocks are bound to the runspace that made them).
            try { & ([scriptblock]::Create($code.ToString())) } catch { Write-Log "  $($_.Exception.Message)" 'ERROR' }
        }
    }
}
. $Helpers
#endregion

#region Data: tweaks ---------------------------------------------------------------
function Reg([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord') {
    @{ Path = $Path; Name = $Name; Value = $Value; Type = $Type }
}
$CDM = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
$ExplorerAdv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'

$Tweaks = @(
    # ---------------- Essential ----------------
    @{ Id = 'RestorePoint'; Group = 'Essential'; Name = 'Create Restore Point'
        Desc = 'Creates a System Restore point before any other tweak runs, so the whole system can be rolled back.'
        NoUndo = 'use System Restore (rstrui.exe) to roll back'
        Script = {
            Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
            # Allow more than one restore point per 24h.
            Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' 'SystemRestorePointCreationFrequency' 0
            Checkpoint-Computer -Description 'Peak Optimizations' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
            Write-Log '  Restore point created.'
        }
    }
    @{ Id = 'TempFiles'; Group = 'Essential'; Name = 'Delete Temporary Files'
        Desc = 'Empties the user and Windows temp folders. Files that are in use are skipped.'
        NoUndo = 'deleted temp files cannot be restored'
        Script = {
            $before = 0; $after = 0
            foreach ($p in @($env:TEMP, "$env:SystemRoot\Temp")) {
                $before += (Get-ChildItem $p -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
                Get-ChildItem $p -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                $after += (Get-ChildItem $p -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
            }
            Write-Log ('  Freed {0:N1} MB' -f (($before - $after) / 1MB))
        }
    }
    @{ Id = 'Telemetry'; Group = 'Essential'; Name = 'Disable Telemetry'
        Desc = 'Turns off diagnostic data, advertising ID, tailored experiences, feedback prompts, Start/lock-screen suggestions, silent app installs and the telemetry scheduled tasks.'
        Registry = @(
            Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0
            Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry' 0
            Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'DoNotShowFeedbackNotifications' 1
            Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
            Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' 'DisabledByGroupPolicy' 1
            Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0
            Reg 'HKCU:\Software\Microsoft\Siuf\Rules' 'NumberOfSIUFInPeriod' 0
            Reg 'HKCU:\Software\Microsoft\Input\TIPC' 'Enabled' 0
            Reg $ExplorerAdv 'Start_TrackProgs' 0
            Reg $CDM 'SystemPaneSuggestionsEnabled' 0
            Reg $CDM 'SilentInstalledAppsEnabled' 0
            Reg $CDM 'SubscribedContent-338388Enabled' 0
            Reg $CDM 'SubscribedContent-338389Enabled' 0
            Reg $CDM 'SubscribedContent-353694Enabled' 0
            Reg $CDM 'SubscribedContent-353696Enabled' 0
            Reg 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting' 'Disabled' 1
        )
        Services = @(@{ Name = 'DiagTrack'; Startup = 'Disabled' })
        Tasks = @(
            '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser'
            '\Microsoft\Windows\Application Experience\ProgramDataUpdater'
            '\Microsoft\Windows\Autochk\Proxy'
            '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator'
            '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip'
            '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector'
            '\Microsoft\Windows\Feedback\Siuf\DmClient'
            '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload'
            '\Microsoft\Windows\Windows Error Reporting\QueueReporting'
        )
    }
    @{ Id = 'ActivityHistory'; Group = 'Essential'; Name = 'Disable Activity History'
        Desc = 'Stops Windows from recording and uploading the apps, files and sites you open (Timeline).'
        Registry = @(
            Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableActivityFeed' 0
            Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' 0
            Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'UploadUserActivities' 0
        )
    }
    @{ Id = 'Location'; Group = 'Essential'; Name = 'Disable Location Tracking'
        Desc = 'Denies apps access to your location and stops automatic offline map updates.'
        Registry = @(
            Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' 'Value' 'Deny' 'String'
            Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\lfsvc\Service\Configuration' 'Status' 0
            Reg 'HKLM:\SYSTEM\Maps' 'AutoUpdateEnabled' 0
        )
    }
    @{ Id = 'GameDVR'; Group = 'Essential'; Name = 'Disable GameDVR'
        Desc = 'Turns off background game recording (Xbox Game Bar captures), which costs FPS.'
        Registry = @(
            Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
            Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
            Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0
        )
    }
    @{ Id = 'ConsumerFeatures'; Group = 'Essential'; Name = 'Disable Consumer Features'
        Desc = 'Stops Windows from automatically installing sponsored games and apps (Candy Crush etc.).'
        Registry = @(Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1)
    }
    @{ Id = 'WifiSense'; Group = 'Essential'; Name = 'Disable Wi-Fi Sense'
        Desc = 'Stops auto-connecting to open hotspots suggested by Microsoft.'
        Registry = @(
            Reg 'HKLM:\SOFTWARE\Microsoft\PolicyManager\default\WiFi\AllowWiFiHotSpotReporting' 'Value' 0
            Reg 'HKLM:\SOFTWARE\Microsoft\PolicyManager\default\WiFi\AllowAutoConnectToWiFiSenseHotspots' 'Value' 0
        )
    }
    @{ Id = 'EndTask'; Group = 'Essential'; Name = 'Enable End Task on Taskbar'
        Desc = 'Adds "End task" to the right-click menu of taskbar apps (Windows 11).'
        Registry = @(Reg "$ExplorerAdv\TaskbarDeveloperSettings" 'TaskbarEndTask' 1)
    }
    @{ Id = 'ServicesManual'; Group = 'Essential'; Name = 'Set Services to Manual'
        Desc = 'Sets non-essential auto-start services to Manual so they only run when needed (they still start on demand). Disables DiagTrack, RetailDemo and RemoteRegistry.'
        Services = @(
            @('MapsBroker', 'TrkWks', 'iphlpsvc', 'PcaSvc', 'CDPSvc', 'stisvc', 'WSAIFabricSvc', 'edgeupdate', 'gupdate', 'AdobeARMservice', 'Fax', 'WerSvc', 'WMPNetworkSvc', 'XblAuthManager', 'XblGameSave', 'XboxNetApiSvc') |
                ForEach-Object { @{ Name = $_; Startup = 'Manual' } }
            @('DiagTrack', 'RetailDemo', 'RemoteRegistry') | ForEach-Object { @{ Name = $_; Startup = 'Disabled' } }
        )
    }
    @{ Id = 'PS7Telemetry'; Group = 'Essential'; Name = 'Disable PowerShell 7 Telemetry'
        Desc = 'Sets POWERSHELL_TELEMETRY_OPTOUT=1 system-wide.'
        Script = { [Environment]::SetEnvironmentVariable('POWERSHELL_TELEMETRY_OPTOUT', '1', 'Machine') }
        Undo = { [Environment]::SetEnvironmentVariable('POWERSHELL_TELEMETRY_OPTOUT', $null, 'Machine') }
    }
    @{ Id = 'Hibernation'; Group = 'Essential'; Name = 'Disable Hibernation'
        Desc = 'Deletes hiberfil.sys (frees GBs equal to a chunk of your RAM). Also disables Fast Startup. Not recommended on laptops you hibernate.'
        Registry = @(Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings' 'ShowHibernateOption' 0)
        Script = { Invoke-Exe powercfg.exe @('/hibernate', 'off') | Out-Null }
        Undo = { Invoke-Exe powercfg.exe @('/hibernate', 'on') | Out-Null }
    }
    @{ Id = 'DiskCleanup'; Group = 'Essential'; Name = 'Run Disk Cleanup'
        Desc = 'Runs Disk Cleanup silently on every category, then cleans the WinSxS component store. Can take several minutes.'
        NoUndo = 'cleaned files cannot be restored'
        Script = {
            $vc = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
            Get-ChildItem $vc -ErrorAction SilentlyContinue | ForEach-Object {
                New-ItemProperty -Path $_.PSPath -Name 'StateFlags0777' -Value 2 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
            }
            Write-Log '  Running Disk Cleanup...'
            Start-Process cleanmgr.exe -ArgumentList '/sagerun:777' -Wait -WindowStyle Hidden
            Write-Log '  Cleaning component store (DISM)...'
            Invoke-Exe DISM.exe @('/Online', '/Cleanup-Image', '/StartComponentCleanup') -Quiet | Out-Null
            Write-Log '  Disk cleanup finished.'
        }
    }

    # ---------------- Advanced ----------------
    @{ Id = 'BackgroundApps'; Group = 'Advanced'; Name = 'Disable Background Apps'
        Desc = 'Stops Store apps from running in the background. Notifications from those apps (Mail, Phone Link, etc.) may stop until opened.'
        Registry = @(
            Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1
            Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BackgroundAppGlobalToggle' 0
        )
    }
    @{ Id = 'Copilot'; Group = 'Advanced'; Name = 'Disable Microsoft Copilot'
        Desc = 'Turns off Copilot via policy, hides its taskbar button and removes the Copilot app.'
        Registry = @(
            Reg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
            Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
            Reg $ExplorerAdv 'ShowCopilotButton' 0
        )
        Script = { Remove-AppxEverywhere @('Microsoft.Copilot', 'Microsoft.Windows.Ai.Copilot.Provider') }
        Undo = { Write-Log '  Policies restored. Reinstall the Copilot app from the Microsoft Store if wanted.' }
    }
    @{ Id = 'Recall'; Group = 'Advanced'; Name = 'Disable Recall'
        Desc = 'Disables Windows Recall snapshots (Copilot+ PCs) via policy and removes the optional feature.'
        Registry = @(
            Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1
            Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'AllowRecallEnablement' 0
        )
        Script = {
            $f = Get-WindowsOptionalFeature -Online -FeatureName Recall -ErrorAction SilentlyContinue
            if ($f -and $f.State -eq 'Enabled') { Disable-WindowsOptionalFeature -Online -FeatureName Recall -NoRestart -ErrorAction Stop | Out-Null; Write-Log '  Recall feature removed (reboot required).' }
        }
    }
    @{ Id = 'Widgets'; Group = 'Advanced'; Name = 'Disable Widgets'
        Desc = 'Removes the Widgets board / News and Interests from the taskbar via policy.'
        Registry = @(Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0)
        Script = { Stop-Process -Name Widgets, WidgetService -Force -ErrorAction SilentlyContinue }
    }
    @{ Id = 'EdgeDebloat'; Group = 'Advanced'; Name = 'Debloat Microsoft Edge'
        Desc = 'Edge policies: no startup boost, no background running, no shopping/sidebar/recommendations, no first-run experience.'
        Registry = @(
            foreach ($n in 'StartupBoostEnabled', 'BackgroundModeEnabled', 'HubsSidebarEnabled', 'EdgeShoppingAssistantEnabled', 'ShowRecommendationsEnabled', 'PersonalizationReportingEnabled', 'EdgeCollectionsEnabled', 'UserFeedbackAllowed', 'SpotlightExperiencesAndRecommendationsEnabled') {
                Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' $n 0
            }
            Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'HideFirstRunExperience' 1
        )
    }
    @{ Id = 'Debloat'; Group = 'Advanced'; Name = 'Remove Bloatware Apps'
        Desc = 'Uninstalls preinstalled apps: Bing News/Weather/Search, Get Help, Tips, Office Hub, Solitaire, People, Power Automate, To Do, Feedback Hub, Maps, Movies & TV, Mixed Reality, Skype, Cortana, Teams (personal), Clipchamp, Journal and sponsored apps (Candy Crush, TikTok, Disney+, Spotify, Prime Video, McAfee...).'
        NoUndo = 'reinstall removed apps from the Microsoft Store'
        Script = {
            Remove-AppxEverywhere @(
                'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.BingSearch', 'Microsoft.GetHelp', 'Microsoft.Getstarted',
                'Microsoft.MicrosoftOfficeHub', 'Microsoft.MicrosoftSolitaireCollection', 'Microsoft.People', 'Microsoft.PowerAutomateDesktop',
                'Microsoft.Todos', 'Microsoft.WindowsFeedbackHub', 'Microsoft.WindowsMaps', 'Microsoft.ZuneVideo', 'Microsoft.MixedReality.Portal',
                'Microsoft.SkypeApp', 'Microsoft.549981C3F5F10', 'MicrosoftTeams', 'MSTeams', 'Clipchamp.Clipchamp', 'Microsoft.MicrosoftJournal',
                'Microsoft.News', 'king.com.CandyCrushSaga', 'king.com.CandyCrushSodaSaga', 'BytedancePte.Ltd.TikTok', 'Disney.37853FC22B2CE',
                'SpotifyAB.SpotifyMusic', 'AmazonVideo.PrimeVideo', 'Facebook.Facebook', '5A894077.McAfeeSecurity'
            )
        }
    }
    @{ Id = 'OneDrive'; Group = 'Advanced'; Name = 'Remove OneDrive'
        Desc = 'Uninstalls OneDrive. Files already in your OneDrive folder stay on disk, but MAKE SURE they are synced first.'
        Script = {
            Stop-Process -Name OneDrive -Force -ErrorAction SilentlyContinue
            $r = if (Test-Winget) { Invoke-Exe winget.exe @('uninstall', '--id', 'Microsoft.OneDrive', '--exact', '--silent', '--accept-source-agreements', '--disable-interactivity') -Quiet }
            if (-not $r -or $r.Code -ne 0) {
                $setup = @("$env:SystemRoot\System32\OneDriveSetup.exe", "$env:SystemRoot\SysWOW64\OneDriveSetup.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
                if ($setup) { Start-Process $setup -ArgumentList '/uninstall' -Wait }
            }
            Write-Log '  OneDrive removed. Your files remain in your user folder.'
        }
        Undo = { if (Test-Winget) { Invoke-Exe winget.exe @('install', '--id', 'Microsoft.OneDrive', '--exact', '--silent', '--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity') | Out-Null } }
    }
    @{ Id = 'UltimatePower'; Group = 'Advanced'; Name = 'Ultimate Performance Power Plan'
        Desc = 'Adds and activates the hidden Ultimate Performance plan. Higher idle power use - best for desktops.'
        Script = {
            $plan = (powercfg.exe /list) -match 'Ultimate Performance' | Select-Object -First 1
            if (-not $plan) { $plan = powercfg.exe -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 }
            if ("$plan" -match '([0-9a-fA-F-]{36})') { powercfg.exe /setactive $Matches[1]; Write-Log '  Ultimate Performance activated.' }
            else { Write-Log '  Could not create the Ultimate Performance plan.' 'WARN' }
        }
        Undo = {
            powercfg.exe /setactive 381b4222-f694-41f0-9685-ff5bb260df2e
            (powercfg.exe /list) -match 'Ultimate Performance' | ForEach-Object { if ($_ -match '([0-9a-fA-F-]{36})') { powercfg.exe /delete $Matches[1] } }
            Write-Log '  Switched back to Balanced.'
        }
    }
    @{ Id = 'VisualFX'; Group = 'Advanced'; Name = 'Set Visual Effects for Performance'
        Desc = 'Turns off animations, shadows and fades (keeps smooth fonts and thumbnails). Sign out to fully apply.'
        Registry = @(
            Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 3
            Reg 'HKCU:\Control Panel\Desktop' 'UserPreferencesMask' ([byte[]](0x90, 0x12, 0x03, 0x80, 0x10, 0x00, 0x00, 0x00)) 'Binary'
            Reg 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '200' 'String'
            Reg 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' 'String'
            Reg $ExplorerAdv 'TaskbarAnimations' 0
            Reg $ExplorerAdv 'ListviewShadow' 0
        )
    }
    @{ Id = 'GamingNetwork'; Group = 'Advanced'; Name = 'Gaming Priority + No Network Throttling'
        Desc = 'Removes multimedia network throttling and gives games higher CPU/GPU scheduling priority.'
        Registry = @(
            Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'NetworkThrottlingIndex' 0xffffffff
            Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'SystemResponsiveness' 10
            Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'GPU Priority' 8
            Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'Priority' 6
            Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'Scheduling Category' 'High' 'String'
            Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'SFIO Priority' 'High' 'String'
        )
    }
    @{ Id = 'FSO'; Group = 'Advanced'; Name = 'Disable Fullscreen Optimizations'
        Desc = 'Forces true exclusive fullscreen in older DirectX games. Can reduce input lag; breaks Game Bar overlays in those games.'
        Registry = @(
            Reg 'HKCU:\System\GameConfigStore' 'GameDVR_DXGIHonorFSEWindowsCompatible' 1
            Reg 'HKCU:\System\GameConfigStore' 'GameDVR_FSEBehaviorMode' 2
            Reg 'HKCU:\System\GameConfigStore' 'GameDVR_HonorUserFSEBehaviorMode' 1
        )
    }
    @{ Id = 'PreferIPv4'; Group = 'Advanced'; Name = 'Prefer IPv4 over IPv6'
        Desc = 'Keeps IPv6 enabled but makes Windows use IPv4 first. Reboot required.'
        Registry = @(Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' 'DisabledComponents' 32)
    }
    @{ Id = 'Teredo'; Group = 'Advanced'; Name = 'Disable Teredo'
        Desc = 'Disables the Teredo IPv6 tunnel. Can lower latency; may affect Xbox Live party chat NAT.'
        Script = { Invoke-Exe netsh.exe @('interface', 'teredo', 'set', 'state', 'disabled') | Out-Null }
        Undo = { Invoke-Exe netsh.exe @('interface', 'teredo', 'set', 'state', 'default') | Out-Null }
    }
    @{ Id = 'OemSoftware'; Group = 'Advanced'; Name = 'Block OEM Device Software Auto-Install'
        Desc = 'Stops Windows from auto-installing manufacturer apps (Razer Synapse etc.) when a device is plugged in.'
        Registry = @(
            Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Metadata' 'PreventDeviceMetadataFromNetwork' 1
            Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata' 'PreventDeviceMetadataFromNetwork' 1
        )
    }
    @{ Id = 'WPBT'; Group = 'Advanced'; Name = 'Disable WPBT Execution'
        Desc = 'Blocks firmware (BIOS) from injecting OEM software into Windows at boot via the Platform Binary Table.'
        Registry = @(Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'DisableWpbtExecution' 1)
    }
    @{ Id = 'UTC'; Group = 'Advanced'; Name = 'Set Hardware Clock to UTC'
        Desc = 'Only for dual-boot with Linux: stops the clock being wrong after switching OS.'
        Registry = @(Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation' 'RealTimeIsUniversal' 1 'QWord')
    }

    # ---------------- Competitive ----------------
    # These never touch Core Isolation / Memory Integrity (VBS, HVCI), Spectre/Meltdown mitigations,
    # DEP, Defender or Secure Boot - anti-cheats such as Vanguard and FACEIT require those.
    @{ Id = 'ForegroundBoost'; Group = 'Competitive'; Name = 'Prioritize the Game Window'
        Desc = 'Win32PrioritySeparation = 0x26: short, variable CPU time slices with a boost for the foreground app (the game). Smoother frame pacing.'
        Registry = @(Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 0x26)
    }
    @{ Id = 'PowerThrottling'; Group = 'Competitive'; Name = 'Disable Power Throttling'
        Desc = 'Stops Windows parking background/launcher processes on slow, low-power CPU states (can cause stutter when tabbing or with overlays). Slightly higher power use on laptops.'
        Registry = @(Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 1)
    }
    @{ Id = 'TimerResolution'; Group = 'Competitive'; Name = 'Global Timer Resolution Requests'
        Desc = 'Windows 11: lets a game''s high-precision timer request apply system-wide again, as on Windows 10. Steadier frame times in games that request it.'
        Registry = @(Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'GlobalTimerResolutionRequests' 1)
    }
    @{ Id = 'HAGS'; Group = 'Competitive'; Name = 'Hardware-Accelerated GPU Scheduling'
        Desc = 'Lets the GPU manage its own memory scheduling. Lower latency on modern GPUs (needed for frame generation). Reboot required.'
        Registry = @(Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2)
    }
    @{ Id = 'WindowedOpt'; Group = 'Competitive'; Name = 'Optimizations for Windowed Games'
        Desc = 'Gives borderless/windowed games the same low-latency flip presentation as exclusive fullscreen. Keeps your other per-GPU graphics settings.'
        Script = {
            $k = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'; $n = 'DirectXUserGlobalSettings'
            Backup-RegValue $k $n
            $parts = @(([string](Get-RegValue $k $n)) -split ';' | Where-Object { $_ -and $_ -notmatch '^SwapEffectUpgradeEnable=' }) + 'SwapEffectUpgradeEnable=1'
            Set-RegValue $k $n (($parts -join ';') + ';') 'String'
        }
        Undo = { Restore-RegValue 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' 'DirectXUserGlobalSettings' }
    }
    @{ Id = 'KeyboardResponse'; Group = 'Competitive'; Name = 'Fastest Keyboard Repeat'
        Desc = 'Shortest repeat delay and fastest repeat rate for held keys. Sign out to apply.'
        Registry = @(
            Reg 'HKCU:\Control Panel\Keyboard' 'KeyboardDelay' '0' 'String'
            Reg 'HKCU:\Control Panel\Keyboard' 'KeyboardSpeed' '31' 'String'
        )
    }
    @{ Id = 'NagleOff'; Group = 'Competitive'; Name = 'Disable Nagle''s Algorithm'
        Desc = 'Sends small TCP packets immediately instead of batching them (TcpAckFrequency/TCPNoDelay on every network adapter). Helps games that use TCP; UDP games are unaffected.'
        Script = {
            $root = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
            foreach ($nic in Get-ChildItem $root -ErrorAction SilentlyContinue) {
                $p = "$root\$($nic.PSChildName)"
                if (-not ((Get-RegValue $p 'DhcpIPAddress') -or (Get-RegValue $p 'IPAddress'))) { continue }
                foreach ($n in 'TcpAckFrequency', 'TCPNoDelay') { Backup-RegValue $p $n; Set-RegValue $p $n 1 }
            }
        }
        Undo = {
            $root = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
            foreach ($nic in Get-ChildItem $root -ErrorAction SilentlyContinue) {
                $p = "$root\$($nic.PSChildName)"
                foreach ($n in 'TcpAckFrequency', 'TCPNoDelay') { if ($sync.Backup.ContainsKey("reg|$p|$n")) { Restore-RegValue $p $n } }
            }
        }
    }
    @{ Id = 'UsbSuspend'; Group = 'Competitive'; Name = 'Disable USB Selective Suspend'
        Desc = 'Stops Windows putting USB devices (mouse, keyboard, headset) to sleep, which can cause a wake-up delay or dropped inputs.'
        Script = {
            foreach ($mode in '/setacvalueindex', '/setdcvalueindex') { powercfg.exe $mode SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 }
            powercfg.exe /setactive SCHEME_CURRENT
        }
        Undo = {
            foreach ($mode in '/setacvalueindex', '/setdcvalueindex') { powercfg.exe $mode SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 1 }
            powercfg.exe /setactive SCHEME_CURRENT
        }
    }
    @{ Id = 'NoP2PUpload'; Group = 'Competitive'; Name = 'Stop Update Sharing to Other PCs'
        Desc = 'Delivery Optimization stops uploading Windows updates to other PCs over the internet, so it can''t eat your upload bandwidth mid-match.'
        Registry = @(Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0)
    }
)
$TweakMap = @{}
foreach ($t in $Tweaks) { $TweakMap[$t.Id] = $t }

$Presets = @{
    Standard = @('RestorePoint', 'TempFiles', 'Telemetry', 'ActivityHistory', 'Location', 'GameDVR', 'ConsumerFeatures', 'WifiSense', 'EndTask', 'ServicesManual', 'PS7Telemetry', 'DiskCleanup')
    Minimal  = @('RestorePoint', 'Telemetry', 'ActivityHistory', 'ConsumerFeatures', 'WifiSense', 'PS7Telemetry', 'EndTask')
    Gaming   = @('RestorePoint', 'TempFiles', 'Telemetry', 'ActivityHistory', 'Location', 'GameDVR', 'ConsumerFeatures', 'WifiSense', 'EndTask', 'ServicesManual', 'PS7Telemetry', 'BackgroundApps', 'UltimatePower', 'GamingNetwork', 'FSO', 'OemSoftware',
        'ForegroundBoost', 'PowerThrottling', 'TimerResolution', 'HAGS', 'WindowedOpt', 'KeyboardResponse', 'NagleOff', 'UsbSuspend', 'NoP2PUpload')
}
#endregion

#region Data: preferences (instant toggles) ------------------------------------------
$ClassicMenuKey = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}'
$Toggles = @(
    @{ Name = 'Dark Theme'; Desc = 'Dark mode for Windows and apps.'; Registry = @(
            @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'AppsUseLightTheme'; On = 0; Off = 1 }
            @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'SystemUsesLightTheme'; On = 0; Off = 1 }) }
    @{ Name = 'Bing Search in Start Menu'; DefaultOn = $true; Explorer = $true; Desc = 'Web results when searching from Start.'; Registry = @(
            @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'; Name = 'BingSearchEnabled'; On = 1; Off = 0 }
            @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'; Name = 'DisableSearchBoxSuggestions'; On = '<Remove>'; Off = 1 }) }
    @{ Name = 'Recommendations in Start'; DefaultOn = $true; Explorer = $true; Desc = 'Recommended files/apps section in the Start menu.'; Registry = @(
            @{ Path = $ExplorerAdv; Name = 'Start_IrisRecommendations'; On = 1; Off = 0 }) }
    @{ Name = 'Show File Extensions'; Explorer = $true; Desc = 'Show .exe, .txt etc. in File Explorer.'; Registry = @(
            @{ Path = $ExplorerAdv; Name = 'HideFileExt'; On = 0; Off = 1 }) }
    @{ Name = 'Show Hidden Files'; Explorer = $true; Desc = 'Show hidden files and folders in File Explorer.'; Registry = @(
            @{ Path = $ExplorerAdv; Name = 'Hidden'; On = 1; Off = 2 }) }
    @{ Name = 'Classic Right-Click Menu'; Explorer = $true; Desc = 'Windows 10 style full context menu on Windows 11.'
        Check = { Test-Path "$ClassicMenuKey\InprocServer32" }
        OnScript = { New-Item -Path "$ClassicMenuKey\InprocServer32" -Force | Out-Null; Set-ItemProperty -Path "$ClassicMenuKey\InprocServer32" -Name '(default)' -Value '' }
        OffScript = { Remove-Item -Path $ClassicMenuKey -Recurse -Force -ErrorAction SilentlyContinue } }
    @{ Name = 'Center Taskbar Items'; DefaultOn = $true; Explorer = $true; Desc = 'Windows 11 centered taskbar (off = left aligned).'; Registry = @(
            @{ Path = $ExplorerAdv; Name = 'TaskbarAl'; On = 1; Off = 0 }) }
    @{ Name = 'Task View Button'; DefaultOn = $true; Explorer = $true; Desc = 'Task View button on the taskbar.'; Registry = @(
            @{ Path = $ExplorerAdv; Name = 'ShowTaskViewButton'; On = 1; Off = 0 }) }
    @{ Name = 'Seconds in Taskbar Clock'; Explorer = $true; Desc = 'Show seconds in the system tray clock.'; Registry = @(
            @{ Path = $ExplorerAdv; Name = 'ShowSecondsInSystemClock'; On = 1; Off = 0 }) }
    @{ Name = 'Snap Assist Flyout'; DefaultOn = $true; Desc = 'Layout flyout when hovering the maximize button.'; Registry = @(
            @{ Path = $ExplorerAdv; Name = 'EnableSnapAssistFlyout'; On = 1; Off = 0 }) }
    @{ Name = 'Game Mode'; DefaultOn = $true; Desc = 'Windows Game Mode (prioritizes the game you are playing).'; Registry = @(
            @{ Path = 'HKCU:\Software\Microsoft\GameBar'; Name = 'AutoGameModeEnabled'; On = 1; Off = 0 }) }
    @{ Name = 'Mouse Acceleration'; DefaultOn = $true; Desc = 'Enhance pointer precision. Most gamers turn this off. Sign out to apply.'; Registry = @(
            @{ Path = 'HKCU:\Control Panel\Mouse'; Name = 'MouseSpeed'; On = '1'; Off = '0'; Type = 'String' }
            @{ Path = 'HKCU:\Control Panel\Mouse'; Name = 'MouseThreshold1'; On = '6'; Off = '0'; Type = 'String' }
            @{ Path = 'HKCU:\Control Panel\Mouse'; Name = 'MouseThreshold2'; On = '10'; Off = '0'; Type = 'String' }) }
    @{ Name = 'Sticky Keys Shortcut'; DefaultOn = $true; Desc = 'Pressing Shift 5 times opens Sticky Keys.'; Registry = @(
            @{ Path = 'HKCU:\Control Panel\Accessibility\StickyKeys'; Name = 'Flags'; On = '510'; Off = '58'; Type = 'String' }) }
    @{ Name = 'NumLock on Startup'; Desc = 'Turn NumLock on at the login screen and after sign-in.'; Registry = @(
            @{ Path = 'Registry::HKEY_USERS\.DEFAULT\Control Panel\Keyboard'; Name = 'InitialKeyboardIndicators'; On = '2'; Off = '0'; Type = 'String' }
            @{ Path = 'HKCU:\Control Panel\Keyboard'; Name = 'InitialKeyboardIndicators'; On = '2'; Off = '0'; Type = 'String' }) }
    @{ Name = 'Verbose Logon Messages'; Desc = 'Show detailed status ("Applying settings...") during sign-in/shutdown.'; Registry = @(
            @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'VerboseStatus'; On = 1; Off = 0 }) }
    @{ Name = 'Detailed BSOD'; Desc = 'Show the stop code parameters instead of the sad face on a blue screen.'; Registry = @(
            @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'; Name = 'DisplayParameters'; On = 1; Off = 0 }
            @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'; Name = 'DisableEmoticon'; On = 1; Off = 0 }) }
)

function Get-ToggleState($T) {
    if ($T.Check) { return [bool](& $T.Check) }
    $r = @($T.Registry)[0]
    $cur = Get-RegValue $r.Path $r.Name
    if ($null -eq $cur) { return [bool]$T.DefaultOn }
    "$cur" -eq "$($r.On)"
}

function Set-Toggle($T, [bool]$On) {
    foreach ($r in @($T.Registry)) {
        if (-not $r) { continue }
        Set-RegValue -Path $r.Path -Name $r.Name -Value $(if ($On) { $r.On } else { $r.Off }) -Type $r.Type
    }
    $code = if ($On) { $T.OnScript } else { $T.OffScript }
    if ($code) { & $code }
}
#endregion

#region Data: apps, features, panels, DNS ------------------------------------------
$AppCatalog = [ordered]@{
    'Browsers'      = 'Brave|Brave.Brave', 'Google Chrome|Google.Chrome', 'Firefox|Mozilla.Firefox', 'LibreWolf|LibreWolf.LibreWolf', 'Vivaldi|Vivaldi.Vivaldi', 'Zen Browser|Zen-Team.Zen-Browser'
    'Communication' = 'Discord|Discord.Discord', 'Signal|OpenWhisperSystems.Signal', 'Telegram|Telegram.TelegramDesktop', 'Zoom|Zoom.Zoom', 'Slack|SlackTechnologies.Slack', 'Thunderbird|Mozilla.Thunderbird'
    'Gaming'        = 'Steam|Valve.Steam', 'Epic Games Launcher|EpicGames.EpicGamesLauncher', 'GOG Galaxy|GOG.Galaxy', 'EA App|ElectronicArts.EADesktop', 'Ubisoft Connect|Ubisoft.Connect', 'Playnite|Playnite.Playnite', 'Prism Launcher|PrismLauncher.PrismLauncher', 'MSI Afterburner|Guru3D.Afterburner'
    'Development'   = 'VS Code|Microsoft.VisualStudioCode', 'Git|Git.Git', 'GitHub Desktop|GitHub.GitHubDesktop', 'Python 3.13|Python.Python.3.13', 'Node.js LTS|OpenJS.NodeJS.LTS', 'Windows Terminal|Microsoft.WindowsTerminal', 'PowerShell 7|Microsoft.PowerShell', 'Notepad++|Notepad++.Notepad++', 'Docker Desktop|Docker.DockerDesktop'
    'Multimedia'    = 'VLC|VideoLAN.VLC', 'Spotify|Spotify.Spotify', 'OBS Studio|OBSProject.OBSStudio', 'Audacity|Audacity.Audacity', 'GIMP|GIMP.GIMP', 'Krita|KDE.Krita', 'HandBrake|HandBrake.HandBrake', 'ShareX|ShareX.ShareX', 'foobar2000|PeterPawlowski.foobar2000', 'K-Lite Codec Pack|CodecGuide.K-LiteCodecPack.Standard'
    'Documents'     = 'LibreOffice|TheDocumentFoundation.LibreOffice', 'ONLYOFFICE|ONLYOFFICE.DesktopEditors', 'Obsidian|Obsidian.Obsidian', 'SumatraPDF|SumatraPDF.SumatraPDF', 'Adobe Acrobat Reader|Adobe.Acrobat.Reader.64-bit'
    'Utilities'     = '7-Zip|7zip.7zip', 'Everything|voidtools.Everything', 'PowerToys|Microsoft.PowerToys', 'Bitwarden|Bitwarden.Bitwarden', 'KeePassXC|KeePassXCTeam.KeePassXC', 'qBittorrent|qBittorrent.qBittorrent', 'Flow Launcher|Flow-Launcher.Flow-Launcher', 'TranslucentTB|CharlesMilette.TranslucentTB', 'Rufus|Rufus.Rufus', 'Ventoy|Ventoy.Ventoy', 'Malwarebytes|Malwarebytes.Malwarebytes', 'BleachBit|BleachBit.BleachBit'
    'System Tools'  = 'CPU-Z|CPUID.CPU-Z', 'HWiNFO|REALiX.HWiNFO', 'CrystalDiskInfo|CrystalDewWorld.CrystalDiskInfo', 'CrystalDiskMark|CrystalDewWorld.CrystalDiskMark', 'WizTree|AntibodySoftware.WizTree', 'Revo Uninstaller|RevoUninstaller.RevoUninstaller', 'Autoruns|Microsoft.Sysinternals.Autoruns', 'Process Explorer|Microsoft.Sysinternals.ProcessExplorer', 'Display Driver Uninstaller|Wagnardsoft.DisplayDriverUninstaller', 'NVCleanstall|TechPowerUp.NVCleanstall'
    'Runtimes'      = '.NET Desktop Runtime 8|Microsoft.DotNet.DesktopRuntime.8', 'VC++ 2015-2022 x64|Microsoft.VCRedist.2015+.x64', 'DirectX End-User Runtime|Microsoft.DirectX', 'Java 21 (Temurin JRE)|EclipseAdoptium.Temurin.21.JRE'
}

$Features = @(
    @{ Name = '.NET Framework 3.5'; Ids = @('NetFx3'); Desc = 'Needed by many older apps and games.' }
    @{ Name = 'Hyper-V'; Ids = @('Microsoft-Hyper-V-All'); Desc = 'Microsoft hypervisor (Pro/Enterprise/Education only).' }
    @{ Name = 'WSL (Linux subsystem)'; Ids = @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform'); Desc = 'Run Linux distros on Windows. Install a distro afterwards with: wsl --install' }
    @{ Name = 'Windows Sandbox'; Ids = @('Containers-DisposableClientVM'); Desc = 'Throwaway desktop for testing untrusted programs (Pro+).' }
    @{ Name = 'Legacy Media / DirectPlay'; Ids = @('LegacyComponents', 'DirectPlay', 'MediaPlayback', 'WindowsMediaPlayer'); Desc = 'DirectPlay for old games plus Windows Media Player.' }
    @{ Name = 'NFS Client'; Ids = @('ServicesForNFS-ClientOnly', 'ClientForNFS-Infrastructure', 'NFS-Administration'); Desc = 'Mount NFS shares from Linux/NAS servers.' }
    @{ Name = 'Telnet Client'; Ids = @('TelnetClient'); Desc = 'Command-line telnet client.' }
)

$LegacyPanels = 'Control Panel|control', 'Network Connections|ncpa.cpl', 'Power Options|powercfg.cpl', 'Sound|mmsys.cpl',
'System Properties|sysdm.cpl', 'User Accounts|netplwiz', 'Device Manager|devmgmt.msc', 'Programs and Features|appwiz.cpl',
'Services|services.msc', 'Disk Management|diskmgmt.msc', 'Event Viewer|eventvwr.msc', 'Task Scheduler|taskschd.msc',
'Region|intl.cpl', 'Printers|control|printers'

$DnsProviders = [ordered]@{
    'Default (from router / DHCP)'  = $null
    'Cloudflare'                    = @('1.1.1.1', '1.0.0.1', '2606:4700:4700::1111', '2606:4700:4700::1001')
    'Cloudflare (block malware)'    = @('1.1.1.2', '1.0.0.2', '2606:4700:4700::1112', '2606:4700:4700::1002')
    'Cloudflare (malware + adult)'  = @('1.1.1.3', '1.0.0.3', '2606:4700:4700::1113', '2606:4700:4700::1003')
    'Google'                        = @('8.8.8.8', '8.8.4.4', '2001:4860:4860::8888', '2001:4860:4860::8844')
    'Quad9 (block malware)'         = @('9.9.9.9', '149.112.112.112', '2620:fe::fe', '2620:fe::9')
    'AdGuard (block ads)'           = @('94.140.14.14', '94.140.15.15', '2a10:50c0::ad1:ff', '2a10:50c0::ad2:ff')
    'OpenDNS'                       = @('208.67.222.222', '208.67.220.220', '2620:119:35::35', '2620:119:53::53')
}
#endregion

#region Games: competitive settings by editing each game's own settings file --------------
function Get-SteamGameDirs([string]$Folder) {
    $steam = Get-RegValue 'HKCU:\Software\Valve\Steam' 'SteamPath'
    if (-not $steam) { $steam = Get-RegValue 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' 'InstallPath' }
    if (-not $steam) { return }
    $libs = @($steam -replace '/', '\')
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path $vdf) {
        foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) { $libs += $m.Groups[1].Value -replace '\\\\', '\' }
    }
    $libs | Select-Object -Unique | ForEach-Object { Join-Path $_ "steamapps\common\$Folder" } | Where-Object { Test-Path -LiteralPath $_ }
}

function Get-EpicGameDirs([string]$DisplayName) {
    Get-ChildItem "$env:ProgramData\Epic\EpicGamesLauncher\Data\Manifests\*.item" -ErrorAction SilentlyContinue |
        ForEach-Object { try { Get-Content $_.FullName -Raw | ConvertFrom-Json } catch { } } |
        Where-Object { $_.DisplayName -eq $DisplayName -and $_.InstallLocation } | ForEach-Object InstallLocation
}

# Only keys that already exist in the file are changed, so nothing unknown is ever added.
# Resolution, sensitivity, keybinds and FPS caps are never touched.
$Games = @(
    @{ Id = 'Fortnite'; Name = 'Fortnite'; Format = 'Ini'
        Process = @('FortniteClient-Win64-Shipping', 'FortniteLauncher')
        FindConfig = { $p = "$env:LOCALAPPDATA\FortniteGame\Saved\Config\WindowsClient\GameUserSettings.ini"; if (Test-Path $p) { $p } }
        FindExe = { Get-EpicGameDirs 'Fortnite' | ForEach-Object { Join-Path $_ 'FortniteGame\Binaries\Win64\FortniteClient-Win64-Shipping.exe' } | Where-Object { Test-Path -LiteralPath $_ } }
        Base = @{
            '/Script/FortniteGame.FortGameUserSettings' = @{ 'bUseVSync' = 'False'; 'bMotionBlur' = 'False'; 'bDisableMouseAcceleration' = 'True' }
        }
        Presets = [ordered]@{
            'Competitive' = @{
                Desc = 'Clear visibility at high FPS: shadows, shading, effects, post-processing, foliage, reflections, global illumination and anti-aliasing low; grass and Nanite off. View distance and textures stay as you set them so far-away players remain visible.'
                Settings = @{
                    'ScalabilityGroups' = @{
                        'sg.ShadowQuality' = '0'; 'sg.GlobalIlluminationQuality' = '0'; 'sg.ReflectionQuality' = '0'; 'sg.PostProcessQuality' = '0'
                        'sg.EffectsQuality' = '0'; 'sg.FoliageQuality' = '0'; 'sg.ShadingQuality' = '0'; 'sg.AntiAliasingQuality' = '0'
                    }
                    '/Script/FortniteGame.FortGameUserSettings' = @{ 'bShowGrass' = 'False'; 'bUseNanite' = 'False' }
                }
            }
            'Max FPS' = @{
                Desc = 'Everything lowest, including textures, terrain, meshes and medium view distance. For weaker PCs or chasing the highest frame rate.'
                Settings = @{
                    'ScalabilityGroups' = @{
                        'sg.ViewDistanceQuality' = '1'; 'sg.TextureQuality' = '0'; 'sg.LandscapeQuality' = '0'
                        'sg.ShadowQuality' = '0'; 'sg.GlobalIlluminationQuality' = '0'; 'sg.ReflectionQuality' = '0'; 'sg.PostProcessQuality' = '0'
                        'sg.EffectsQuality' = '0'; 'sg.FoliageQuality' = '0'; 'sg.ShadingQuality' = '0'; 'sg.AntiAliasingQuality' = '0'
                    }
                    'PerformanceMode' = @{ 'MeshQuality' = '0' }
                    '/Script/FortniteGame.FortGameUserSettings' = @{ 'bShowGrass' = 'False'; 'bUseNanite' = 'False' }
                }
            }
            'Balanced' = @{
                Desc = 'Good-looking but responsive: high textures and epic view distance, medium-high effects, V-Sync and motion blur still off.'
                Settings = @{
                    'ScalabilityGroups' = @{
                        'sg.ViewDistanceQuality' = '3'; 'sg.TextureQuality' = '3'; 'sg.ShadowQuality' = '2'; 'sg.GlobalIlluminationQuality' = '2'
                        'sg.ReflectionQuality' = '2'; 'sg.PostProcessQuality' = '1'; 'sg.EffectsQuality' = '2'; 'sg.FoliageQuality' = '2'
                        'sg.ShadingQuality' = '2'; 'sg.AntiAliasingQuality' = '2'
                    }
                    '/Script/FortniteGame.FortGameUserSettings' = @{ 'bShowGrass' = 'True' }
                }
            }
        }
    }
    @{ Id = 'Rust'; Name = 'Rust'; Format = 'Cfg'
        Process = @('RustClient')
        FindConfig = { Get-SteamGameDirs 'Rust' | ForEach-Object { Join-Path $_ 'cfg\client.cfg' } | Where-Object { Test-Path -LiteralPath $_ } }
        FindExe = { Get-SteamGameDirs 'Rust' | ForEach-Object { Join-Path $_ 'RustClient.exe' } | Where-Object { Test-Path -LiteralPath $_ } }
        Base = @{
            'graphics.vsync' = '0'; 'graphics.maxqueuedframes' = '1'; 'effects.motionblur' = 'False'; 'effects.lensdirt' = 'False'
            'effects.vignet' = 'False'; 'graphics.dof' = 'False'
        }
        Presets = [ordered]@{
            'Competitive' = @{
                Desc = 'Clean image at high FPS: AO, bloom, sun shafts, volumetric clouds, grass displacement, contact shadows and gibs off; lowest shadow lights and water. 1 queued frame and no V-Sync for lower input lag.'
                Settings = @{
                    'effects.ao' = 'False'; 'effects.bloom' = 'False'; 'effects.shafts' = 'False'; 'graphics.volumetric_clouds' = '0'
                    'grass.displacement' = 'False'; 'graphics.contactshadows' = 'False'; 'effects.maxgibs' = '0'; 'graphics.shadowlights' = '0'
                    'water.quality' = '0'; 'water.reflections' = '0'
                }
            }
            'Max FPS' = @{
                Desc = 'Competitive plus lowest grass, trees, terrain and particles. Less grass also makes players easier to spot.'
                Settings = @{
                    'effects.ao' = 'False'; 'effects.bloom' = 'False'; 'effects.shafts' = 'False'; 'graphics.volumetric_clouds' = '0'
                    'grass.displacement' = 'False'; 'graphics.contactshadows' = 'False'; 'effects.maxgibs' = '0'; 'graphics.shadowlights' = '0'
                    'water.quality' = '0'; 'water.reflections' = '0'
                    'grass.quality' = '0'; 'tree.quality' = '0'; 'tree.meshes' = '0'; 'terrain.quality' = '0'; 'particle.quality' = '0'
                }
            }
            'Balanced' = @{
                Desc = 'Nice visuals with low latency: AO, sun shafts, medium clouds, water and shadow lights on; motion blur, lens dirt, vignette, depth of field and V-Sync still off.'
                Settings = @{
                    'effects.ao' = 'True'; 'effects.bloom' = 'False'; 'effects.shafts' = 'True'; 'graphics.volumetric_clouds' = '2'
                    'grass.displacement' = 'True'; 'graphics.shadowlights' = '1'; 'water.quality' = '1'; 'water.reflections' = '1'
                }
            }
        }
    }
    @{ Id = 'Siege'; Name = 'Rainbow Six Siege'; Format = 'Ini'
        Process = @('RainbowSix', 'RainbowSix_Vulkan', 'RainbowSix_BE')
        FindConfig = {
            $docs = [Environment]::GetFolderPath('MyDocuments')
            Get-ChildItem (Join-Path $docs 'My Games') -Directory -Filter 'Rainbow Six*' -ErrorAction SilentlyContinue |
                ForEach-Object { Get-ChildItem $_.FullName -Recurse -Depth 1 -Filter 'GameSettings.ini' -ErrorAction SilentlyContinue } | ForEach-Object FullName
        }
        FindExe = {
            $dirs = @(Get-SteamGameDirs "Tom Clancy's Rainbow Six Siege")
            $ubi = Get-RegValue 'HKLM:\SOFTWARE\WOW6432Node\Ubisoft\Launcher\Installs\635' 'InstallDir'
            if ($ubi) { $dirs += $ubi }
            foreach ($d in $dirs) { 'RainbowSix.exe', 'RainbowSix_Vulkan.exe' | ForEach-Object { Join-Path $d $_ } | Where-Object { Test-Path -LiteralPath $_ } }
        }
        # Siege's section names change between seasons, so keys match in any section ('*').
        # Shadow scale in Siege X: 0 Off, 1 Low, 2 Medium, 3 High, 4 Ultra.
        Base = @{
            '*' = @{
                'OverallQualityLevelName' = 'Custom'; 'VSync' = '0'; 'UseLetterbox' = '0'; 'LensEffects' = '0'; 'DOF' = '0'
                'RawInputMouseKeyboard' = '1'
                'ZoomInDepthOfField' = '0'   # name used by older seasons
            }
        }
        Presets = [ordered]@{
            'Competitive' = @{
                Desc = 'Shadows HIGH so enemy shadows show around corners and under doors; reflections, ambient occlusion and visual effects off; lens effects, depth of field, letterbox and V-Sync off; raw mouse input on. Applied to every Ubisoft profile.'
                Settings = @{ '*' = @{ 'Shadow' = '3'; 'Reflection' = '0'; 'AO' = '0'; 'VFX' = '0'; 'AmbientOcclusion' = '0'; 'ReflectionQuality' = '0' } }
            }
            'Max FPS' = @{
                Desc = 'Everything low for the highest frame rate, but shadows stay on MEDIUM so you still see enemy shadows. Lens effects, depth of field and V-Sync off; raw mouse input on.'
                Settings = @{
                    '*' = @{
                        'Shadow' = '2'; 'Reflection' = '0'; 'AO' = '0'; 'VFX' = '0'; 'Geometry' = '0'; 'Lighting' = '0'; 'Texture' = '0'
                        'TextureFiltering' = '0'; 'AmbientOcclusion' = '0'; 'ReflectionQuality' = '0'
                    }
                }
            }
            'Balanced' = @{
                Desc = 'High shadows plus medium textures, geometry, lighting and effects for a cleaner image; lens effects, depth of field and V-Sync still off.'
                Settings = @{ '*' = @{ 'Shadow' = '3'; 'Reflection' = '1'; 'AO' = '1'; 'VFX' = '1'; 'Geometry' = '2'; 'Lighting' = '2'; 'Texture' = '2'; 'TextureFiltering' = '2' } }
            }
        }
    }
)

$GpuPrefKey = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'

# Base settings overlaid with the chosen preset. Ini settings are nested by section.
function Get-PresetSettings($Game, [string]$Preset) {
    $merged = @{}
    foreach ($src in $Game.Base, $Game.Presets[$Preset].Settings) {
        foreach ($k in $src.Keys) {
            if ($Game.Format -ne 'Ini') { $merged[$k] = $src[$k]; continue }
            if (-not $merged.ContainsKey($k)) { $merged[$k] = @{} }
            foreach ($key in $src[$k].Keys) { $merged[$k][$key] = $src[$k][$key] }
        }
    }
    $merged
}

function Read-TextFile([string]$Path) {
    $reader = New-Object System.IO.StreamReader($Path, $true)
    try { $text = $reader.ReadToEnd(); $enc = $reader.CurrentEncoding } finally { $reader.Close() }
    # StreamReader reports UTF-8 when there is no BOM; write such files back without one.
    $b = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = $b.Length -ge 2 -and (($b[0] -eq 0xEF -and $b[1] -eq 0xBB) -or ($b[0] -eq 0xFF -and $b[1] -eq 0xFE) -or ($b[0] -eq 0xFE -and $b[1] -eq 0xFF))
    if (-not $hasBom) { $enc = New-Object System.Text.UTF8Encoding($false) }
    @{ Text = $text; Encoding = $enc }
}

function Update-ConfigFile([string]$Path, [string]$Format, [hashtable]$Settings) {
    $file = Read-TextFile $Path
    $nl = if ($file.Text -match "`r`n") { "`r`n" } else { "`n" }
    $lines = $file.Text -split "`r?`n"
    $section = ''
    $changed = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($Format -eq 'Ini') {
            if ($lines[$i] -match '^\s*\[(.+)\]\s*$') { $section = $Matches[1]; continue }
            if ($lines[$i] -notmatch '^\s*([^=;#\s][^=]*?)\s*=(.*)$') { continue }
            $key = $Matches[1]; $old = $Matches[2]; $want = $null
            foreach ($s in $section, '*') {
                if ($Settings.ContainsKey($s) -and $Settings[$s].ContainsKey($key)) { $want = $Settings[$s][$key]; break }
            }
            if ($null -eq $want -or $old -ceq $want) { continue }
            $lines[$i] = "$key=$want"
        } else {
            if ($lines[$i] -notmatch '^\s*(\S+)\s+"(.*)"\s*$') { continue }
            $key = $Matches[1]; $old = $Matches[2]
            if (-not $Settings.ContainsKey($key) -or $old -ceq $Settings[$key]) { continue }
            $lines[$i] = '{0} "{1}"' -f $key, $Settings[$key]
        }
        $changed++
    }
    if ($changed) { [System.IO.File]::WriteAllText($Path, ($lines -join $nl), $file.Encoding) }
    $changed
}

function Test-GameRunning($Game) {
    if (Get-Process -Name $Game.Process -ErrorAction SilentlyContinue) {
        [System.Windows.MessageBox]::Show("Close $($Game.Name) first - games overwrite their settings file when they exit.", $AppName) | Out-Null
        return $true
    }
    $false
}

function Invoke-GameOptimize($Game, [string]$Preset) {
    if (Test-GameRunning $Game) { return }
    $files = @(& $Game.FindConfig)
    if (-not $files) {
        Write-Log "$($Game.Name): settings file not found. Launch the game once, change any setting, close it, then try again." 'WARN'
        return
    }
    Write-Log "=== Optimize $($Game.Name): $Preset preset ==="
    $settings = Get-PresetSettings $Game $Preset
    $dir = Join-Path $DataDir ("GameBackups\{0}\{1}" -f $Game.Id, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $manifest = @{ Files = @(); Gpu = @() }
    $n = 0
    foreach ($f in $files) {
        $n++
        $bak = Join-Path $dir ('{0}-{1}' -f $n, (Split-Path $f -Leaf))
        Copy-Item -LiteralPath $f -Destination $bak -Force
        $manifest.Files += @{ Original = $f; Backup = $bak }
        try {
            $count = Update-ConfigFile -Path $f -Format $Game.Format -Settings $settings
            Write-Log "  ${f}: $count setting(s) changed"
        } catch { Write-Log "  ${f}: $($_.Exception.Message)" 'ERROR' }
    }
    foreach ($exe in @(& $Game.FindExe)) {
        $manifest.Gpu += @{ Exe = $exe; Old = (Get-RegValue $GpuPrefKey $exe) }
        Set-RegValue $GpuPrefKey $exe 'GpuPreference=2;' 'String'
        Write-Log "  Windows graphics preference set to High performance for $(Split-Path $exe -Leaf)"
    }
    $manifest | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $dir 'manifest.json') -Encoding UTF8
    Write-Log "$($Game.Name) optimized ($Preset). Backup: $dir"
}

function Restore-GameOriginal($Game) {
    if (Test-GameRunning $Game) { return }
    $root = Join-Path $DataDir "GameBackups\$($Game.Id)"
    # The oldest backup holds the settings from before Peak Optimizations first touched the game.
    $first = Get-ChildItem $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -First 1
    if (-not $first) { Write-Log "$($Game.Name): no backup to restore."; return }
    $m = Get-Content (Join-Path $first.FullName 'manifest.json') -Raw | ConvertFrom-Json
    foreach ($f in @($m.Files)) {
        if (-not $f) { continue }
        Copy-Item -LiteralPath $f.Backup -Destination $f.Original -Force
        Write-Log "  Restored $($f.Original)"
    }
    foreach ($g in @($m.Gpu)) {
        if (-not $g) { continue }
        $old = if ($null -eq $g.Old) { '<Remove>' } else { $g.Old }
        Set-RegValue $GpuPrefKey $g.Exe $old 'String'
    }
    Remove-Item $root -Recurse -Force
    Write-Log "$($Game.Name): original settings restored."
}
#endregion

#region UI definition ------------------------------------------------------------------
$xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Peak Optimizations" Width="1180" Height="800" MinWidth="940" MinHeight="620"
        WindowStartupLocation="CenterScreen" Background="#14141C" Foreground="#E6E6F0"
        FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#2A2A3A"/>
      <Setter Property="Foreground" Value="#E6E6F0"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Margin" Value="4"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.82"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.65"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="AccentButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#7C5CFF"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#E6E6F0"/>
      <Setter Property="Margin" Value="0,3"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>
    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Foreground" Value="#E6E6F0"/>
      <Setter Property="Margin" Value="0,5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <DockPanel Background="Transparent">
              <Border x:Name="track" DockPanel.Dock="Right" Width="38" Height="20" CornerRadius="10" Background="#3A3A50" Margin="10,0,0,0">
                <Ellipse x:Name="knob" Width="14" Height="14" Fill="White" HorizontalAlignment="Left" Margin="3,0"/>
              </Border>
              <ContentPresenter VerticalAlignment="Center"/>
            </DockPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="track" Property="Background" Value="#7C5CFF"/>
                <Setter TargetName="knob" Property="HorizontalAlignment" Value="Right"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#1C1C28"/>
      <Setter Property="Foreground" Value="#E6E6F0"/>
      <Setter Property="BorderBrush" Value="#2E2E40"/>
      <Setter Property="CaretBrush" Value="White"/>
    </Style>
    <Style TargetType="TabItem">
      <Setter Property="Foreground" Value="#9A9AB0"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="bd" Padding="16,8" Margin="0,0,4,0" Background="Transparent" BorderThickness="0,0,0,2" BorderBrush="Transparent">
              <ContentPresenter ContentSource="Header" TextElement.Foreground="{TemplateBinding Foreground}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="#7C5CFF"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Spin" TargetType="RepeatButton">
      <Setter Property="Width" Value="18"/>
      <Setter Property="Height" Value="12"/>
      <Setter Property="Margin" Value="0,0,0,1"/>
      <Setter Property="Delay" Value="400"/>
      <Setter Property="Interval" Value="60"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RepeatButton">
            <Border x:Name="b" Background="#2A2A3A" CornerRadius="3">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#3A3A50"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="RadioButton">
      <Setter Property="Foreground" Value="#E6E6F0"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#1C1C28"/>
      <Setter Property="CornerRadius" Value="10"/>
      <Setter Property="Padding" Value="14"/>
      <Setter Property="Margin" Value="0,0,10,10"/>
    </Style>
    <Style x:Key="H" TargetType="TextBlock">
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,0,0,8"/>
    </Style>
    <Style x:Key="Muted" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#9A9AB0"/>
    </Style>
  </Window.Resources>

  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="150"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <DockPanel Grid.Row="0" Margin="0,0,0,6">
      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
        <Button x:Name="BtnImport" Content="Import Config" ToolTip="Load app/tweak/feature selections from a JSON file"/>
        <Button x:Name="BtnExport" Content="Export Config" ToolTip="Save current app/tweak/feature selections to a JSON file"/>
      </StackPanel>
      <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
        <TextBlock Text="PEAK" FontSize="22" FontWeight="Bold" Foreground="#7C5CFF"/>
        <TextBlock Text=" OPTIMIZATIONS" FontSize="22" FontWeight="Light"/>
        <TextBlock x:Name="TxtVersion" Margin="10,0,0,4" VerticalAlignment="Bottom" Style="{StaticResource Muted}"/>
      </StackPanel>
    </DockPanel>

    <TabControl Grid.Row="1" x:Name="Tabs" Background="Transparent" BorderThickness="0" Padding="0,12,0,0">

      <TabItem Header="Home">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel>
            <TextBlock Style="{StaticResource H}" Text="System Overview"/>
            <WrapPanel x:Name="InfoPanel">
              <TextBlock Text="Reading system information..." Style="{StaticResource Muted}"/>
            </WrapPanel>
            <TextBlock Style="{StaticResource H}" Text="Quick Actions" Margin="0,8,0,8"/>
            <WrapPanel>
              <Button x:Name="BtnQuickRestore" Content="Create Restore Point" Style="{StaticResource AccentButton}"/>
              <Button x:Name="BtnQuickBackground" Content="End Background Apps"/>
              <Button x:Name="BtnQuickTemp" Content="Clean Temp Files"/>
              <Button x:Name="BtnQuickExplorer" Content="Restart Explorer"/>
              <Button x:Name="BtnQuickRefresh" Content="Refresh Info"/>
              <Button x:Name="BtnOpenData" Content="Open Logs / Backup Folder"/>
            </WrapPanel>
            <Border Style="{StaticResource Card}" Margin="4,14,0,0" HorizontalAlignment="Left" MaxWidth="760">
              <TextBlock TextWrapping="Wrap" Style="{StaticResource Muted}"
                Text="Tip: create a restore point before running tweaks. Each tweak records the original registry and service values before changing them, so 'Undo Selected' on the Tweaks tab puts things back exactly as they were. Hover any item to see what it does."/>
            </Border>
          </StackPanel>
        </ScrollViewer>
      </TabItem>

      <TabItem Header="Background" x:Name="TabBackground">
        <DockPanel>
          <Border DockPanel.Dock="Top" Style="{StaticResource Card}" Padding="14,10">
            <DockPanel>
              <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
                <Button x:Name="BtnBgRefresh" Content="Refresh"/>
                <Button x:Name="BtnBgEnd" Content="End Selected" Style="{StaticResource AccentButton}"/>
              </StackPanel>
              <StackPanel>
                <TextBlock x:Name="TxtBgSummary" FontWeight="SemiBold" Text="Scanning..." Margin="0,0,0,4"/>
                <TextBlock Style="{StaticResource Muted}" TextWrapping="Wrap" FontSize="12"
                  Text="Apps running in the background without a window. Recommended ones are pre-selected - ending them frees memory and CPU and can't harm Windows; they start again when you open them or restart. Windows, security, anti-cheat and driver processes are never listed."/>
              </StackPanel>
            </DockPanel>
          </Border>
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition/>
              <ColumnDefinition/>
            </Grid.ColumnDefinitions>
            <Border Grid.Column="0" Style="{StaticResource Card}">
              <DockPanel>
                <TextBlock DockPanel.Dock="Top" Style="{StaticResource H}" Text="Running in the Background"/>
                <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="BgPanel" Margin="0,0,6,0"/></ScrollViewer>
              </DockPanel>
            </Border>
            <Border Grid.Column="1" Style="{StaticResource Card}" Margin="0,0,0,10">
              <DockPanel>
                <DockPanel DockPanel.Dock="Top">
                  <Button x:Name="BtnStartupRecommended" DockPanel.Dock="Right" Content="Turn Off Recommended" VerticalAlignment="Top" Margin="8,0,0,0"/>
                  <StackPanel>
                    <TextBlock Style="{StaticResource H}" Text="Start with Windows" Margin="0"/>
                    <TextBlock Style="{StaticResource Muted}" FontSize="12" TextWrapping="Wrap" Margin="0,2,0,8"
                      Text="Stop apps you don't need from starting when you sign in. Same switch as Task Manager's Startup tab - turn it back on any time."/>
                  </StackPanel>
                </DockPanel>
                <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="StartupPanel" Margin="0,0,6,0"/></ScrollViewer>
              </DockPanel>
            </Border>
          </Grid>
        </DockPanel>
      </TabItem>

      <TabItem Header="Install">
        <DockPanel>
          <DockPanel DockPanel.Dock="Top" Margin="0,0,0,8">
            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
              <Button x:Name="BtnInstall" Content="Install / Upgrade Selected" Style="{StaticResource AccentButton}"/>
              <Button x:Name="BtnUninstall" Content="Uninstall Selected"/>
              <Button x:Name="BtnUpgradeAll" Content="Upgrade All Apps" ToolTip="Runs winget upgrade --all for everything on this PC"/>
              <Button x:Name="BtnSelectInstalled" Content="Select Installed"/>
              <Button x:Name="BtnClearApps" Content="Clear"/>
            </StackPanel>
            <Grid Margin="4" MaxWidth="320" HorizontalAlignment="Left" Width="300">
              <TextBox x:Name="TxtSearch" VerticalContentAlignment="Center" Padding="8,6"/>
              <TextBlock x:Name="TxtSearchHint" Text="Search apps..." IsHitTestVisible="False" Margin="12,0" VerticalAlignment="Center" Style="{StaticResource Muted}"/>
            </Grid>
          </DockPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <WrapPanel x:Name="AppPanel"/>
          </ScrollViewer>
        </DockPanel>
      </TabItem>

      <TabItem Header="Tweaks">
        <DockPanel>
          <DockPanel DockPanel.Dock="Bottom" Margin="0,4,0,0">
            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
              <Button x:Name="BtnUndoTweaks" Content="Undo Selected"/>
              <Button x:Name="BtnRunTweaks" Content="Run Tweaks" Style="{StaticResource AccentButton}"/>
            </StackPanel>
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="Presets:" VerticalAlignment="Center" Margin="4,0,4,0" Style="{StaticResource Muted}"/>
              <Button x:Name="BtnPresetStandard" Content="Standard"/>
              <Button x:Name="BtnPresetMinimal" Content="Minimal"/>
              <Button x:Name="BtnPresetGaming" Content="Gaming"/>
              <Button x:Name="BtnPresetClear" Content="Clear"/>
            </StackPanel>
          </DockPanel>
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition/>
              <ColumnDefinition/>
              <ColumnDefinition/>
              <ColumnDefinition/>
            </Grid.ColumnDefinitions>
            <Border Grid.Column="0" Style="{StaticResource Card}">
              <DockPanel>
                <TextBlock DockPanel.Dock="Top" Style="{StaticResource H}" Text="Essential Tweaks"/>
                <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="EssentialPanel"/></ScrollViewer>
              </DockPanel>
            </Border>
            <Border Grid.Column="1" Style="{StaticResource Card}">
              <DockPanel>
                <StackPanel DockPanel.Dock="Top">
                  <TextBlock Style="{StaticResource H}" Text="Competitive Tweaks" Margin="0"/>
                  <TextBlock Text="Core-isolation safe: never turns off Memory Integrity, VBS, CPU mitigations, DEP or Defender, so anti-cheats like Vanguard and FACEIT still work."
                             Foreground="#5FD38D" FontSize="12" TextWrapping="Wrap" Margin="0,2,0,8"/>
                </StackPanel>
                <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="CompetitivePanel"/></ScrollViewer>
              </DockPanel>
            </Border>
            <Border Grid.Column="2" Style="{StaticResource Card}">
              <DockPanel>
                <StackPanel DockPanel.Dock="Top">
                  <TextBlock Style="{StaticResource H}" Text="Advanced Tweaks" Margin="0"/>
                  <TextBlock Text="Caution: read each tooltip before selecting." Foreground="#FFB454" FontSize="12" Margin="0,2,0,8"/>
                </StackPanel>
                <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="AdvancedPanel"/></ScrollViewer>
              </DockPanel>
            </Border>
            <Border Grid.Column="3" Style="{StaticResource Card}" Margin="0,0,0,10">
              <DockPanel>
                <StackPanel DockPanel.Dock="Top">
                  <TextBlock Style="{StaticResource H}" Text="Preferences" Margin="0"/>
                  <TextBlock Text="Applied instantly when switched." Style="{StaticResource Muted}" FontSize="12" Margin="0,2,0,8"/>
                </StackPanel>
                <Button x:Name="BtnRestartExplorer" DockPanel.Dock="Bottom" Content="Restart Explorer to apply" Margin="0,8,0,0"/>
                <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="TogglePanel" Margin="0,0,6,0"/></ScrollViewer>
              </DockPanel>
            </Border>
          </Grid>
        </DockPanel>
      </TabItem>

      <TabItem Header="Games">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel>
            <DockPanel Margin="0,0,0,8">
              <Button x:Name="BtnRescanGames" DockPanel.Dock="Right" Content="Re-scan for Games" VerticalAlignment="Top"/>
              <StackPanel>
                <TextBlock Style="{StaticResource H}" Text="Competitive Game Settings"/>
                <TextBlock Style="{StaticResource Muted}" TextWrapping="Wrap" MaxWidth="820" HorizontalAlignment="Left"
                  Text="Edits each game's own settings file for higher FPS and better visibility, and sets Windows to run the game on your high-performance GPU. Close the game first. Your resolution, sensitivity, keybinds and FPS cap are not changed. The original file is backed up, and Restore Original puts it back. For Windows-side gaming tweaks, use the Gaming preset on the Tweaks tab."/>
              </StackPanel>
            </DockPanel>
            <WrapPanel x:Name="GamePanel"/>
          </StackPanel>
        </ScrollViewer>
      </TabItem>

      <TabItem Header="Macros">
        <DockPanel>
          <Border DockPanel.Dock="Top" Style="{StaticResource Card}" Padding="14,10">
            <DockPanel>
              <CheckBox x:Name="ChkMacrosEnabled" DockPanel.Dock="Right" Style="{StaticResource Switch}" Content="Hotkeys enabled" VerticalAlignment="Center" Margin="16,0,0,0"/>
              <StackPanel>
                <TextBlock x:Name="TxtMacroState" Text="Stopped. Turn hotkeys on to play saved macros with their keys." FontWeight="SemiBold" Margin="0,0,0,4"/>
                <TextBlock TextWrapping="Wrap" Foreground="#FFB454" FontSize="12"
                  Text="Using macros in online games can break their rules - anti-cheats (Easy Anti-Cheat, BattlEye, Vanguard, Ricochet) may flag automated input and ban the account. Use macros for single-player games, desktop tasks or where the game allows them. Macros only run while this app is open."/>
              </StackPanel>
            </DockPanel>
          </Border>
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="250"/>
              <ColumnDefinition/>
            </Grid.ColumnDefinitions>

            <Border Grid.Column="0" Style="{StaticResource Card}">
              <DockPanel>
                <TextBlock DockPanel.Dock="Top" Style="{StaticResource H}" Text="Your Macros"/>
                <WrapPanel DockPanel.Dock="Bottom" Margin="-4,8,0,0">
                  <Button x:Name="BtnMacroNew" Content="New" Style="{StaticResource AccentButton}"/>
                  <Button x:Name="BtnMacroDelete" Content="Delete"/>
                  <Button x:Name="BtnMacroImport" Content="Import"/>
                  <Button x:Name="BtnMacroExport" Content="Export"/>
                  <Button x:Name="BtnMacroExportAll" Content="Export All"/>
                </WrapPanel>
                <ListBox x:Name="LstMacros" Background="Transparent" BorderThickness="0" Foreground="#E6E6F0" FontSize="13"/>
              </DockPanel>
            </Border>

            <Border Grid.Column="1" Style="{StaticResource Card}" Margin="0,0,0,10">
              <DockPanel x:Name="MacroEditor" IsEnabled="False">
                <DockPanel DockPanel.Dock="Bottom" Margin="0,10,0,0">
                  <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                    <Button x:Name="BtnMacroSave" Content="Save" Width="100" Style="{StaticResource AccentButton}" IsEnabled="False"/>
                    <Button x:Name="BtnMacroCancel" Content="Cancel" Width="100" IsEnabled="False" ToolTip="Discard unsaved changes"/>
                  </StackPanel>
                  <TextBlock x:Name="TxtMacroSummary" Style="{StaticResource Muted}" VerticalAlignment="Center" TextWrapping="Wrap"/>
                </DockPanel>
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition/>
                    <ColumnDefinition Width="160"/>
                    <ColumnDefinition Width="220"/>
                  </Grid.ColumnDefinitions>

                  <DockPanel Grid.Column="0">
                    <DockPanel DockPanel.Dock="Top" Margin="0,0,0,8">
                      <TextBlock Text="Name:" VerticalAlignment="Center" Margin="0,0,8,0"/>
                      <TextBox x:Name="TxtMacroName" Padding="6,4"/>
                    </DockPanel>
                    <TextBlock DockPanel.Dock="Top" Text="Steps" Style="{StaticResource Muted}" Margin="0,0,0,4"/>
                    <ListBox x:Name="LstMacroSteps" Background="#16161F" BorderThickness="0" Foreground="#C8C8D8" FontFamily="Consolas" FontSize="12"/>
                  </DockPanel>

                  <StackPanel Grid.Column="1" Margin="12,0,0,0">
                    <Button x:Name="BtnMacroStartRec" Content="Start Recording" Style="{StaticResource AccentButton}" Margin="0,0,0,6"
                            ToolTip="Starts after a 3 second countdown. New steps go after the selected step. Press F8 to stop."/>
                    <Button x:Name="BtnMacroStopRec" Content="Stop Recording" Margin="0,0,0,18" IsEnabled="False"/>
                    <Button x:Name="BtnMacroInsert" Content="Insert &gt;&gt;" Margin="0,0,0,6" ToolTip="Insert a key, delay, mouse button or scroll step after the selected step"/>
                    <Button x:Name="BtnMacroDeleteStep" Content="Delete" Margin="0,0,0,6"/>
                    <Button x:Name="BtnMacroUp" Content="Move Up" Margin="0,0,0,6"/>
                    <Button x:Name="BtnMacroDown" Content="Move Down" Margin="0,0,0,18"/>
                    <DockPanel ToolTip="Edits the selected Delay step. Otherwise it is the length used by Insert &gt; Delay.">
                      <TextBlock Text="Delay (s):" VerticalAlignment="Center" Margin="0,0,6,0"/>
                      <StackPanel DockPanel.Dock="Right" Margin="2,0,0,0" VerticalAlignment="Center">
                        <RepeatButton x:Name="BtnDelayUp" Style="{StaticResource Spin}"><Path Data="M0,4 L4,0 L8,4 Z" Fill="#E6E6F0"/></RepeatButton>
                        <RepeatButton x:Name="BtnDelayDown" Style="{StaticResource Spin}"><Path Data="M0,0 L8,0 L4,4 Z" Fill="#E6E6F0"/></RepeatButton>
                      </StackPanel>
                      <TextBox x:Name="TxtDelay" Text="0.05" Padding="4,3" VerticalContentAlignment="Center"/>
                    </DockPanel>
                  </StackPanel>

                  <StackPanel Grid.Column="2" Margin="16,0,0,0">
                    <TextBlock Text="When recording" Style="{StaticResource Muted}" Margin="0,0,0,4"/>
                    <CheckBox x:Name="ChkRecDelays" Content="Record delays" IsChecked="True"/>
                    <CheckBox x:Name="ChkRecMoves" Content="Mouse moves"/>
                    <CheckBox x:Name="ChkRecClicks" Content="Mouse clicks" IsChecked="True"/>
                    <CheckBox x:Name="ChkRecClickPos" Content="Click position" Margin="22,3,0,3"
                              IsEnabled="{Binding IsChecked, ElementName=ChkRecClicks}"
                              ToolTip="Clicks move the cursor to where they were recorded. Leave off for games."/>
                    <TextBlock Text="Bound to:" Style="{StaticResource Muted}" Margin="0,14,0,4"/>
                    <Border Background="#16161F" CornerRadius="6" Padding="8,6">
                      <TextBlock x:Name="TxtMacroBound" Text="(none)" HorizontalAlignment="Center" FontWeight="SemiBold"/>
                    </Border>
                    <Button x:Name="BtnMacroBind" Content="Bind to Key" Margin="0,6,0,14"/>
                    <RadioButton x:Name="RbMacroOnce" GroupName="MacroRepeat" Content="Play only once" Margin="0,3"/>
                    <DockPanel Margin="0,3">
                      <StackPanel DockPanel.Dock="Right" Margin="2,0,0,0" VerticalAlignment="Center">
                        <RepeatButton x:Name="BtnRepeatUp" Style="{StaticResource Spin}"><Path Data="M0,4 L4,0 L8,4 Z" Fill="#E6E6F0"/></RepeatButton>
                        <RepeatButton x:Name="BtnRepeatDown" Style="{StaticResource Spin}"><Path Data="M0,0 L8,0 L4,4 Z" Fill="#E6E6F0"/></RepeatButton>
                      </StackPanel>
                      <TextBox x:Name="TxtRepeatCount" DockPanel.Dock="Right" Width="56" Text="2" Padding="4,2" Margin="8,0,0,0" IsEnabled="False"/>
                      <RadioButton x:Name="RbMacroRepeat" GroupName="MacroRepeat" Content="Repeat" VerticalAlignment="Center"/>
                    </DockPanel>
                    <RadioButton x:Name="RbMacroLoop" GroupName="MacroRepeat" Content="Repeat until stopped" Margin="0,3"/>
                    <DockPanel Margin="0,10,0,0">
                      <TextBlock Text="Speed:" VerticalAlignment="Center" Margin="0,0,8,0"/>
                      <ComboBox x:Name="CmbMacroSpeed" Padding="6,3"/>
                    </DockPanel>
                    <WrapPanel Margin="-4,10,0,0">
                      <Button x:Name="BtnMacroPlay" Content="Test Play" ToolTip="Plays the current edits after a 3 second countdown"/>
                      <Button x:Name="BtnMacroStopPlay" Content="Stop"/>
                    </WrapPanel>
                  </StackPanel>
                </Grid>
              </DockPanel>
            </Border>
          </Grid>
        </DockPanel>
      </TabItem>

      <TabItem Header="Display">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel>
            <Border x:Name="DisplayConfirm" Style="{StaticResource Card}" Background="#2B2440" Visibility="Collapsed" MaxWidth="860" HorizontalAlignment="Left">
              <DockPanel>
                <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                  <Button x:Name="BtnDisplayKeep" Content="Keep Changes" Style="{StaticResource AccentButton}"/>
                  <Button x:Name="BtnDisplayRevert" Content="Revert"/>
                </StackPanel>
                <TextBlock x:Name="TxtDisplayConfirm" TextWrapping="Wrap" VerticalAlignment="Center" FontWeight="SemiBold" Margin="0,0,12,0"/>
              </DockPanel>
            </Border>
            <DockPanel Margin="0,0,0,8">
              <Button x:Name="BtnDisplayRefresh" DockPanel.Dock="Right" Content="Refresh" VerticalAlignment="Top"/>
              <StackPanel>
                <TextBlock Style="{StaticResource H}" Text="Monitors"/>
                <TextBlock Style="{StaticResource Muted}" TextWrapping="Wrap" MaxWidth="820" HorizontalAlignment="Left"
                  Text="Change the resolution and refresh rate of each monitor. Only modes your monitor reports are listed. If the screen goes black or looks wrong, just wait - it switches back by itself after 15 seconds. Many high-refresh monitors are left at 60 Hz by default; Max Refresh Rate fixes that."/>
              </StackPanel>
            </DockPanel>
            <WrapPanel x:Name="DisplayPanel"/>
          </StackPanel>
        </ScrollViewer>
      </TabItem>

      <TabItem Header="Peripherals">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel>
            <WrapPanel>
              <Border Style="{StaticResource Card}" Width="430">
                <StackPanel>
                  <TextBlock Style="{StaticResource H}" Text="Mouse"/>
                  <DockPanel>
                    <TextBlock x:Name="TxtMouseSpeed" DockPanel.Dock="Right" Style="{StaticResource Muted}"/>
                    <TextBlock Text="Pointer speed"/>
                  </DockPanel>
                  <Slider x:Name="SldMouseSpeed" Minimum="1" Maximum="20" IsSnapToTickEnabled="True" TickFrequency="1" Margin="0,4,0,12"
                          ToolTip="10 is Windows' default and moves the pointer 1:1 with your mouse. Set sensitivity with DPI and in-game instead."/>
                  <CheckBox x:Name="ChkMouseAccel" Style="{StaticResource Switch}" Content="Enhance pointer precision (acceleration)"
                            ToolTip="Off gives consistent aim: the same hand movement always moves the same distance. Recommended off for games."/>
                  <CheckBox x:Name="ChkMouseSwap" Style="{StaticResource Switch}" Content="Swap left and right buttons (left-handed)"/>
                  <DockPanel Margin="0,10,0,0">
                    <TextBlock x:Name="TxtScrollLines" DockPanel.Dock="Right" Style="{StaticResource Muted}"/>
                    <TextBlock Text="Scroll wheel moves"/>
                  </DockPanel>
                  <Slider x:Name="SldScrollLines" Minimum="1" Maximum="20" IsSnapToTickEnabled="True" TickFrequency="1" Margin="0,4,0,12"/>
                  <DockPanel>
                    <TextBlock x:Name="TxtDoubleClick" DockPanel.Dock="Right" Style="{StaticResource Muted}"/>
                    <TextBlock Text="Double-click speed (slower - faster)"/>
                  </DockPanel>
                  <Slider x:Name="SldDoubleClick" Minimum="200" Maximum="900" IsSnapToTickEnabled="True" TickFrequency="50" IsDirectionReversed="True" Margin="0,4,0,10"/>
                  <Button x:Name="BtnMouseDefaults" Content="Windows Defaults" HorizontalAlignment="Left" Margin="-4,0,0,0"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}" Width="430">
                <StackPanel>
                  <TextBlock Style="{StaticResource H}" Text="Keyboard"/>
                  <DockPanel>
                    <TextBlock x:Name="TxtKeyDelay" DockPanel.Dock="Right" Style="{StaticResource Muted}"/>
                    <TextBlock Text="Repeat delay (long - short)"/>
                  </DockPanel>
                  <Slider x:Name="SldKeyDelay" Minimum="0" Maximum="3" IsSnapToTickEnabled="True" TickFrequency="1" TickPlacement="BottomRight" IsDirectionReversed="True" Margin="0,4,0,12"
                          ToolTip="How long you hold a key before it starts repeating."/>
                  <DockPanel>
                    <TextBlock x:Name="TxtKeyRate" DockPanel.Dock="Right" Style="{StaticResource Muted}"/>
                    <TextBlock Text="Repeat rate (slow - fast)"/>
                  </DockPanel>
                  <Slider x:Name="SldKeyRate" Minimum="0" Maximum="31" IsSnapToTickEnabled="True" TickFrequency="1" Margin="0,4,0,12"/>
                  <TextBlock Text="Test: click below and hold a key" Style="{StaticResource Muted}" Margin="0,0,0,4"/>
                  <TextBox Padding="6,5" Margin="0,0,0,10"/>
                  <Button x:Name="BtnKeyboardDefaults" Content="Windows Defaults" HorizontalAlignment="Left" Margin="-4,0,0,0"/>
                </StackPanel>
              </Border>
            </WrapPanel>
            <Border Style="{StaticResource Card}" MaxWidth="870" HorizontalAlignment="Left">
              <StackPanel>
                <DockPanel>
                  <Button x:Name="BtnRefreshDevices" DockPanel.Dock="Right" Content="Refresh" VerticalAlignment="Top"/>
                  <TextBlock Style="{StaticResource H}" Text="Connected Keyboards and Mice"/>
                </DockPanel>
                <StackPanel x:Name="DevicePanel"/>
                <TextBlock Style="{StaticResource Muted}" TextWrapping="Wrap" FontSize="12" Margin="0,8,0,0"
                  Text="DPI, polling rate, lighting and on-board profiles are stored in the mouse or keyboard itself - change those in its maker's software (Logitech G HUB, Razer Synapse, SteelSeries GG, Corsair iCUE...)."/>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>
      </TabItem>

      <TabItem Header="Drivers">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel>
            <TextBlock Style="{StaticResource H}" Text="Your Graphics Card and Motherboard"/>
            <WrapPanel x:Name="HwPanel">
              <TextBlock Text="Detecting hardware..." Style="{StaticResource Muted}" Margin="0,0,0,10"/>
            </WrapPanel>
            <Border Style="{StaticResource Card}" MaxWidth="1100" HorizontalAlignment="Left">
              <StackPanel>
                <DockPanel>
                  <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Top">
                    <Button x:Name="BtnScanDrivers" Content="Scan for Driver Updates" Style="{StaticResource AccentButton}"/>
                    <Button x:Name="BtnInstallDrivers" Content="Install Selected" IsEnabled="False"/>
                  </StackPanel>
                  <StackPanel>
                    <TextBlock Style="{StaticResource H}" Text="Windows Update Drivers"/>
                    <TextBlock Style="{StaticResource Muted}" TextWrapping="Wrap"
                      Text="Microsoft's driver catalog, matched to the exact hardware IDs in this PC (chipset, network, audio, Bluetooth, peripherals). Graphics drivers here are usually older than the ones from AMD/NVIDIA/Intel, so they are never pre-selected - use the button on your graphics card above instead."/>
                  </StackPanel>
                </DockPanel>
                <StackPanel x:Name="DriverList" Margin="0,10,0,0"/>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>
      </TabItem>

      <TabItem Header="Config">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <WrapPanel>
            <Border Style="{StaticResource Card}" Width="330">
              <StackPanel>
                <TextBlock Style="{StaticResource H}" Text="Windows Features"/>
                <StackPanel x:Name="FeaturePanel"/>
                <Button x:Name="BtnInstallFeatures" Content="Install Selected Features" Style="{StaticResource AccentButton}" Margin="0,10,0,0"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}" Width="330">
              <StackPanel>
                <TextBlock Style="{StaticResource H}" Text="Fixes"/>
                <Button x:Name="BtnFixNetwork" Content="Reset Network Stack" Margin="0,3" ToolTip="Winsock + TCP/IP reset, renew IP, flush DNS. Reboot afterwards."/>
                <Button x:Name="BtnFixUpdate" Content="Reset Windows Update" Margin="0,3" ToolTip="Stops update services and rebuilds SoftwareDistribution and catroot2."/>
                <Button x:Name="BtnFixSfc" Content="Repair System Files (DISM + SFC)" Margin="0,3" ToolTip="DISM /RestoreHealth then sfc /scannow. Takes 10-30 minutes."/>
                <Button x:Name="BtnFixComponent" Content="Clean Up Component Store" Margin="0,3" ToolTip="DISM /StartComponentCleanup - removes superseded update files."/>
                <Button x:Name="BtnFixWinget" Content="Reset Winget Sources" Margin="0,3" ToolTip="Fixes winget source errors."/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}" Width="330">
              <StackPanel>
                <TextBlock Style="{StaticResource H}" Text="DNS"/>
                <TextBlock Text="Applies to all connected network adapters." Style="{StaticResource Muted}" TextWrapping="Wrap" Margin="0,0,0,8"/>
                <ComboBox x:Name="CmbDns" Padding="8,6"/>
                <Button x:Name="BtnApplyDns" Content="Apply DNS" Style="{StaticResource AccentButton}" Margin="0,10,0,0"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}" Width="680">
              <StackPanel>
                <TextBlock Style="{StaticResource H}" Text="Legacy Windows Panels"/>
                <WrapPanel x:Name="LegacyPanel"/>
              </StackPanel>
            </Border>
          </WrapPanel>
        </ScrollViewer>
      </TabItem>

      <TabItem Header="Updates">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel MaxWidth="860" HorizontalAlignment="Left">
            <Border Style="{StaticResource Card}">
              <DockPanel>
                <Button x:Name="BtnUpdSecurity" DockPanel.Dock="Right" Content="Apply" Width="110" Style="{StaticResource AccentButton}" VerticalAlignment="Center"/>
                <StackPanel>
                  <TextBlock Style="{StaticResource H}" Text="Security Updates Only (Recommended)"/>
                  <TextBlock Style="{StaticResource Muted}" TextWrapping="Wrap" Text="Security/quality updates install 4 days after release (so broken ones get pulled first). Feature updates are delayed for 1 year. Drivers are no longer pushed through Windows Update, and the PC will not auto-restart while you are signed in."/>
                </StackPanel>
              </DockPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <DockPanel>
                <Button x:Name="BtnUpdDefault" DockPanel.Dock="Right" Content="Apply" Width="110" VerticalAlignment="Center"/>
                <StackPanel>
                  <TextBlock Style="{StaticResource H}" Text="Default Settings"/>
                  <TextBlock Style="{StaticResource Muted}" TextWrapping="Wrap" Text="Removes all update policies set here and re-enables the update services. Windows Update behaves as it does out of the box."/>
                </StackPanel>
              </DockPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <DockPanel>
                <Button x:Name="BtnUpdDisable" DockPanel.Dock="Right" Content="Apply" Width="110" Background="#B3364B" VerticalAlignment="Center"/>
                <StackPanel>
                  <TextBlock Style="{StaticResource H}" Text="Disable All Updates (Not Recommended)"/>
                  <TextBlock Style="{StaticResource Muted}" TextWrapping="Wrap" Text="Stops Windows Update completely, including security patches. Your PC will become vulnerable over time. Only for offline or special-purpose machines. Revert with Default Settings."/>
                </StackPanel>
              </DockPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>
      </TabItem>
    </TabControl>

    <Border Grid.Row="2" Style="{StaticResource Card}" Margin="0,6,0,0" Padding="12,8">
      <DockPanel>
        <DockPanel DockPanel.Dock="Top">
          <Button x:Name="BtnClearLog" DockPanel.Dock="Right" Content="Clear" Padding="10,2" Margin="0"/>
          <TextBlock Text="Activity Log" Style="{StaticResource Muted}" VerticalAlignment="Center"/>
        </DockPanel>
        <TextBox x:Name="LogBox" IsReadOnly="True" Background="Transparent" BorderThickness="0" Foreground="#C8C8D8"
                 FontFamily="Consolas" FontSize="12" Margin="0,4,0,0"
                 VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
      </DockPanel>
    </Border>

    <DockPanel Grid.Row="3" Margin="2,8,2,0">
      <ProgressBar x:Name="Progress" DockPanel.Dock="Right" Width="220" Height="6" Visibility="Hidden"
                   Foreground="#7C5CFF" Background="#2A2A3A" BorderThickness="0"/>
      <TextBlock x:Name="TxtStatus" Text="Ready" Style="{StaticResource Muted}"/>
    </DockPanel>
  </Grid>
</Window>
'@

try {
    $window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$xamlText)))
} catch {
    [System.Windows.MessageBox]::Show("Failed to load the interface:`n$($_.Exception.Message)", $AppName, 'OK', 'Error') | Out-Null
    exit 1
}
$ui = @{}
# Controls are PascalCase; lowercase names are template parts and can't be found from the window.
foreach ($m in [regex]::Matches($xamlText, 'x:Name="([A-Z]\w+)"')) { $ui[$m.Groups[1].Value] = $window.FindName($m.Groups[1].Value) }
$ui.TxtVersion.Text = "v$AppVersion"
$iconPath = Join-Path $PSScriptRoot 'PeakOptimizations.ico'
if (Test-Path $iconPath) { try { $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]$iconPath) } catch { } }
#endregion

#region Background job runner -----------------------------------------------------------
function Start-PeakJob {
    param([string]$Title, [scriptblock]$Script, [hashtable]$Params = @{}, [scriptblock]$OnComplete)
    if ($sync.Busy) {
        [System.Windows.MessageBox]::Show("Please wait - '$($sync.Job.Title)' is still running.", $AppName) | Out-Null
        return
    }
    $sync.Busy = $true
    $sync.Result = $null
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('sync', $sync)
    foreach ($k in $Params.Keys) { $rs.SessionStateProxy.SetVariable($k, $Params[$k]) }
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $code = $Helpers.ToString() + "`ntry {`n" + $Script.ToString() + "`n} finally { Save-Backup }"
    [void]$ps.AddScript($code)
    $sync.Job = @{ Title = $Title; PS = $ps; RS = $rs; Handle = $ps.BeginInvoke(); OnComplete = $OnComplete }
    $ui.TxtStatus.Text = "Working: $Title..."
    $ui.Progress.IsIndeterminate = $true
    $ui.Progress.Visibility = 'Visible'
    Write-Log "=== $Title ==="
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(150)
$timer.Add_Tick({
    $line = $null
    $sb = New-Object System.Text.StringBuilder
    while ($sync.Log.TryDequeue([ref]$line)) { [void]$sb.AppendLine($line) }
    if ($sb.Length -gt 0) { $ui.LogBox.AppendText($sb.ToString()); $ui.LogBox.ScrollToEnd() }
    if ($script:MacroEngineReady) { Update-MacroState }

    $job = $sync.Job
    if ($job -and $job.Handle.IsCompleted) {
        $sync.Job = $null
        try { [void]$job.PS.EndInvoke($job.Handle) } catch { Write-Log $_.Exception.Message 'ERROR' }
        foreach ($e in $job.PS.Streams.Error) { Write-Log $e.ToString() 'ERROR' }
        $job.PS.Dispose(); $job.RS.Dispose()
        $sync.Busy = $false
        Write-Log "=== Finished: $($job.Title) ==="
        $ui.TxtStatus.Text = "Ready - last task: $($job.Title)"
        $ui.Progress.IsIndeterminate = $false
        $ui.Progress.Visibility = 'Hidden'
        # Last, because it may start a follow-up job.
        if ($job.OnComplete) { try { & $job.OnComplete } catch { Write-Log $_.Exception.Message 'ERROR' } }
    }
})
#endregion

#region Build dynamic UI ----------------------------------------------------------------
function New-Card([string]$Title, [double]$Width) {
    $card = New-Object System.Windows.Controls.Border
    $card.Style = $window.FindResource('Card')
    if ($Width) { $card.Width = $Width }
    $stack = New-Object System.Windows.Controls.StackPanel
    $h = New-Object System.Windows.Controls.TextBlock
    $h.Text = $Title
    $h.Style = $window.FindResource('H')
    [void]$stack.Children.Add($h)
    $card.Child = $stack
    $card
}

function New-Check([string]$Content, [string]$Tip, $Tag) {
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Content = $Content
    if ($Tip) { $cb.ToolTip = $Tip }
    $cb.Tag = $Tag
    $cb
}

# Apps
$AppChecks = New-Object System.Collections.Generic.List[object]
$AppCards = New-Object System.Collections.Generic.List[object]
foreach ($cat in $AppCatalog.Keys) {
    $card = New-Card $cat 250
    foreach ($entry in $AppCatalog[$cat]) {
        $name, $id = $entry -split '\|', 2
        $cb = New-Check $name $id $id
        [void]$card.Child.Children.Add($cb)
        $AppChecks.Add($cb)
    }
    [void]$ui.AppPanel.Children.Add($card)
    $AppCards.Add($card)
}

# Tweaks
$TweakChecks = New-Object System.Collections.Generic.List[object]
foreach ($t in $Tweaks) {
    # Wrapping label so the four tweak columns stay readable at small window sizes.
    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = $t.Name; $label.TextWrapping = 'Wrap'
    $cb = New-Check $null $t.Desc $t.Id
    $cb.Content = $label
    $panel = @{ Essential = $ui.EssentialPanel; Competitive = $ui.CompetitivePanel; Advanced = $ui.AdvancedPanel }[$t.Group]
    [void]$panel.Children.Add($cb)
    $TweakChecks.Add($cb)
}

# Preferences
foreach ($t in $Toggles) {
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Style = $window.FindResource('Switch')
    $cb.Content = $t.Name
    $cb.ToolTip = $t.Desc
    $cb.Tag = $t
    try { $cb.IsChecked = Get-ToggleState $t } catch { }
    $cb.Add_Click({
        param($s, $e)
        $t = $s.Tag
        $on = [bool]$s.IsChecked
        try {
            Set-Toggle $t $on
            $note = if ($t.Explorer) { ' (restart Explorer to see it)' } else { '' }
            Write-Log ('{0}: {1}{2}' -f $t.Name, $(if ($on) { 'On' } else { 'Off' }), $note)
        } catch {
            Write-Log "$($t.Name): $($_.Exception.Message)" 'ERROR'
            $s.IsChecked = -not $on
        }
    })
    [void]$ui.TogglePanel.Children.Add($cb)
}

# Features
$FeatureChecks = New-Object System.Collections.Generic.List[object]
foreach ($f in $Features) {
    $cb = New-Check $f.Name $f.Desc $f
    [void]$ui.FeaturePanel.Children.Add($cb)
    $FeatureChecks.Add($cb)
}

# Legacy panels
foreach ($p in $LegacyPanels) {
    $parts = $p -split '\|'
    $btn = New-Object System.Windows.Controls.Button
    $btn.Content = $parts[0]
    $btn.Tag = $parts
    $btn.Add_Click({
        param($s, $e)
        $parts = $s.Tag
        try {
            if ($parts.Count -gt 2) { Start-Process $parts[1] -ArgumentList $parts[2] } else { Start-Process $parts[1] }
        } catch { Write-Log "Could not open $($parts[0]): $($_.Exception.Message)" 'ERROR' }
    })
    [void]$ui.LegacyPanel.Children.Add($btn)
}

# DNS
foreach ($k in $DnsProviders.Keys) { [void]$ui.CmbDns.Items.Add($k) }
$ui.CmbDns.SelectedIndex = 0

# Games
$Brush = New-Object System.Windows.Media.BrushConverter
function Update-GameStatus($Game) {
    $files = @(& $Game.FindConfig)
    $exes = @(& $Game.FindExe)
    $hasBackup = [bool](Get-ChildItem (Join-Path $DataDir "GameBackups\$($Game.Id)") -Directory -ErrorAction SilentlyContinue)
    if ($files) {
        $Game.Status.Text = 'Settings file found' + $(if ($files.Count -gt 1) { " ($($files.Count) profiles)" } else { '' }) +
            $(if ($exes) { ' - game install found' } else { '' }) + $(if ($hasBackup) { ' - optimized (backup saved)' } else { '' })
        $Game.Status.Foreground = $Brush.ConvertFromString('#5FD38D')
    } else {
        $Game.Status.Text = 'Not found - launch the game once, then Re-scan'
        $Game.Status.Foreground = $Brush.ConvertFromString('#9A9AB0')
    }
    $Game.ApplyButton.IsEnabled = [bool]$files
    $Game.RestoreButton.IsEnabled = $hasBackup
}

foreach ($g in $Games) {
    $card = New-Card $g.Name 360
    $status = New-Object System.Windows.Controls.TextBlock
    $status.FontSize = 12
    $status.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
    $desc = New-Object System.Windows.Controls.TextBlock
    $desc.TextWrapping = 'Wrap'
    $desc.MinHeight = 64
    $desc.Style = $window.FindResource('Muted')
    $presetRow = New-Object System.Windows.Controls.DockPanel
    $presetRow.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
    $presetLabel = New-Object System.Windows.Controls.TextBlock
    $presetLabel.Text = 'Preset:'; $presetLabel.VerticalAlignment = 'Center'; $presetLabel.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $combo = New-Object System.Windows.Controls.ComboBox
    $combo.Padding = [System.Windows.Thickness]::new(8, 4, 8, 4)
    foreach ($p in $g.Presets.Keys) { [void]$combo.Items.Add($p) }
    $combo.Tag = @{ Game = $g; Desc = $desc }
    $combo.Add_SelectionChanged({ param($s, $e); $s.Tag.Desc.Text = $s.Tag.Game.Presets[[string]$s.SelectedItem].Desc })
    $combo.SelectedIndex = 0
    [void]$presetRow.Children.Add($presetLabel); [void]$presetRow.Children.Add($combo)
    $g.PresetCombo = $combo
    $buttons = New-Object System.Windows.Controls.WrapPanel
    $buttons.Margin = [System.Windows.Thickness]::new(-4, 10, 0, 0)
    $apply = New-Object System.Windows.Controls.Button
    $apply.Content = 'Apply Preset'; $apply.Style = $window.FindResource('AccentButton')
    $restore = New-Object System.Windows.Controls.Button
    $restore.Content = 'Restore Original'
    $open = New-Object System.Windows.Controls.Button
    $open.Content = 'Open Folder'
    foreach ($b in $apply, $restore, $open) { $b.Tag = $g; [void]$buttons.Children.Add($b) }
    $apply.Add_Click({ param($s, $e); Invoke-GameOptimize $s.Tag ([string]$s.Tag.PresetCombo.SelectedItem); Update-GameStatus $s.Tag })
    $restore.Add_Click({
        param($s, $e)
        $ok = [System.Windows.MessageBox]::Show("Restore $($s.Tag.Name)'s settings to how they were before Peak Optimizations first changed them?", $AppName, 'YesNo')
        if ($ok -eq 'Yes') { Restore-GameOriginal $s.Tag; Update-GameStatus $s.Tag }
    })
    $open.Add_Click({
        param($s, $e)
        $f = @(& $s.Tag.FindConfig) | Select-Object -First 1
        if ($f) { Start-Process explorer.exe "/select,`"$f`"" } else { Write-Log "$($s.Tag.Name): settings file not found." 'WARN' }
    })
    foreach ($c in $status, $presetRow, $desc, $buttons) { [void]$card.Child.Children.Add($c) }
    $g.Status = $status; $g.ApplyButton = $apply; $g.RestoreButton = $restore
    [void]$ui.GamePanel.Children.Add($card)
    try { Update-GameStatus $g } catch { $status.Text = "Scan failed: $($_.Exception.Message)" }
}
$ui.BtnRescanGames.Add_Click({ foreach ($g in $Games) { Update-GameStatus $g }; Write-Log 'Re-scanned for games.' })
#endregion

#region Actions ---------------------------------------------------------------------------
function Get-Checked($List) { @($List | Where-Object { $_.IsChecked }) }

function Start-Tweaks([object[]]$TweakList, [bool]$Undo) {
    if (-not $TweakList) { [System.Windows.MessageBox]::Show('Select at least one tweak first.', $AppName) | Out-Null; return }
    $title = if ($Undo) { "Undo $($TweakList.Count) tweak(s)" } else { "Run $($TweakList.Count) tweak(s)" }
    Start-PeakJob -Title $title -Params @{ TweakList = $TweakList; UndoMode = $Undo } -Script {
        $list = if ($UndoMode) { [array]::Reverse($TweakList); $TweakList } else { $TweakList }
        foreach ($t in $list) { Invoke-Tweak -Tweak $t -Undo:$UndoMode }
        Write-Log 'Done. Some changes need an Explorer restart, sign-out or reboot to fully apply.'
    }
}

function New-LinkButton([string]$Text, [string]$Url, [switch]$Accent) {
    $b = New-Object System.Windows.Controls.Button
    $b.Content = $Text; $b.Tag = $Url; $b.ToolTip = $Url
    if ($Accent) { $b.Style = $window.FindResource('AccentButton') }
    $b.Add_Click({ param($s, $e); Start-Process $s.Tag })
    $b
}

function New-TextLine([string]$Text, [switch]$Muted, [string]$Color) {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text; $t.TextWrapping = 'Wrap'; $t.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
    if ($Muted) { $t.Style = $window.FindResource('Muted') }
    if ($Color) { $t.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Color) }
    $t
}

function Format-Age($Date) {
    if (-not $Date) { return 'date unknown' }
    $days = [int]((Get-Date) - $Date).TotalDays
    '{0:d MMM yyyy} ({1} days old)' -f $Date, $days
}

function Show-Hardware($Gpus, $Board) {
    $ui.HwPanel.Children.Clear()
    foreach ($g in $Gpus) {
        $card = New-Card $g.Name 400
        $kind = if ($g.Integrated) { "$($g.Vendor) integrated graphics" } else { "$($g.Vendor) graphics card" }
        [void]$card.Child.Children.Add((New-TextLine $kind -Muted))
        [void]$card.Child.Children.Add((New-TextLine "Driver $($g.Version) - $(Format-Age $g.Date)"))
        if ($g.Date -and ((Get-Date) - $g.Date).TotalDays -gt 120) {
            [void]$card.Child.Children.Add((New-TextLine 'This driver is over 4 months old - an update is likely available.' -Color '#FFB454'))
        }
        if ($g.Integrated -and $g.Vendor -eq 'AMD') {
            [void]$card.Child.Children.Add((New-TextLine 'Updated by the same AMD Software: Adrenalin package as Radeon graphics cards.' -Muted))
        }
        $row = New-Object System.Windows.Controls.WrapPanel
        $row.Margin = [System.Windows.Thickness]::new(-4, 6, 0, 0)
        [void]$row.Children.Add((New-LinkButton 'Get Latest Driver' $g.Url -Accent))
        [void]$card.Child.Children.Add($row)
        [void]$ui.HwPanel.Children.Add($card)
    }
    if ($Board) {
        $card = New-Card $Board.Name 400
        [void]$card.Child.Children.Add((New-TextLine 'Motherboard' -Muted))
        [void]$card.Child.Children.Add((New-TextLine "BIOS $($Board.Bios) - $(Format-Age $Board.BiosDate)"))
        [void]$card.Child.Children.Add((New-TextLine 'BIOS updates are never flashed automatically. Follow the board maker''s instructions, and don''t turn the PC off while flashing.' -Muted))
        $row = New-Object System.Windows.Controls.WrapPanel
        $row.Margin = [System.Windows.Thickness]::new(-4, 6, 0, 0)
        [void]$row.Children.Add((New-LinkButton 'Drivers and BIOS Page' $Board.SupportUrl -Accent))
        [void]$row.Children.Add((New-LinkButton "$($Board.ChipsetName) Chipset Driver" $Board.ChipsetUrl))
        [void]$card.Child.Children.Add($row)
        [void]$ui.HwPanel.Children.Add($card)
    }
}

function Start-InfoRefresh {
    Start-PeakJob -Title 'Read system info' -Script {
        $os = Get-CimInstance Win32_OperatingSystem
        $cs = Get-CimInstance Win32_ComputerSystem
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        $gpu = (Get-CimInstance Win32_VideoController | ForEach-Object Name) -join ', '
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
        $ver = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $up = (Get-Date) - $os.LastBootUpTime
        $hvci = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled'
        $info = [ordered]@{
            'Operating System' = '{0} {1} (build {2}.{3})' -f $os.Caption, $ver.DisplayVersion, $os.BuildNumber, $ver.UBR
            'Processor'        = '{0} - {1} cores / {2} threads' -f $cpu.Name.Trim(), $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors
            'Graphics'         = $gpu
            'Memory'           = '{0:N1} GB total, {1:N1} GB free' -f ($cs.TotalPhysicalMemory / 1GB), ($os.FreePhysicalMemory * 1KB / 1GB)
            'System Drive'     = '{0} {1:N0} GB free of {2:N0} GB' -f $env:SystemDrive, ($disk.FreeSpace / 1GB), ($disk.Size / 1GB)
            'Uptime'           = '{0}d {1}h {2}m' -f $up.Days, $up.Hours, $up.Minutes
            'Device'           = '{0} {1}' -f $cs.Manufacturer, $cs.Model
            'Power Plan'       = ((powercfg.exe /getactivescheme) -replace '^.*\((.*)\)\s*$', '$1')
            'Core Isolation'   = if ($hvci -eq 1) { 'Memory Integrity ON (kept on by every tweak here)' } else { 'Memory Integrity off' }
        }

        # Driver pages: use the exact product page when the vendor has one, else the vendor's auto-detect page.
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        function Test-Url([string]$Url) {
            try { (Invoke-WebRequest $Url -UseBasicParsing -TimeoutSec 4 -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)').StatusCode -eq 200 } catch { $false }
        }
        $amdBase = 'https://www.amd.com/en/support/downloads/drivers.html'
        $gpus = foreach ($v in Get-CimInstance Win32_VideoController) {
            if ($v.PNPDeviceID -notmatch 'VEN_(10DE|1002|8086)') { continue }
            $vendor = @{ '10DE' = 'NVIDIA'; '1002' = 'AMD'; '8086' = 'Intel' }[$Matches[1]]
            $url = @{
                NVIDIA = 'https://www.nvidia.com/en-us/drivers/'
                AMD    = 'https://www.amd.com/en/support/download/drivers.html'
                Intel  = 'https://www.intel.com/content/www/us/en/support/detect.html'
            }[$vendor]
            if ($vendor -eq 'AMD' -and $v.Name -match 'RX\s+(\d)(\d{3})\s*(XTX|XT|GRE)?') {
                $slug = ('amd-radeon-rx-{0}{1}{2}' -f $Matches[1], $Matches[2], $(if ($Matches[3]) { '-' + $Matches[3].ToLower() } else { '' }))
                $exact = "$amdBase/graphics/radeon-rx/radeon-rx-$($Matches[1])000-series/$slug.html"
                if (Test-Url $exact) { $url = $exact }
            }
            $date = if ($v.DriverDate) { [datetime]$v.DriverDate } else { $null }
            [pscustomobject]@{
                Name       = $v.Name.Trim()
                Vendor     = $vendor
                Integrated = $v.Name -match 'Radeon\(TM\) Graphics|Radeon Graphics|UHD|Iris|Vega \d+ Graphics|Intel\(R\) Graphics'
                Version    = $v.DriverVersion
                Date       = $date
                Url        = $url
            }
        }

        $bb = Get-CimInstance Win32_BaseBoard
        $bios = Get-CimInstance Win32_BIOS
        $maker = "$($bb.Manufacturer)"
        $domain = switch -Regex ($maker) {
            'gigabyte' { 'gigabyte.com' } 'asus' { 'asus.com' } 'micro-star|msi' { 'msi.com' } 'asrock' { 'asrock.com' }
            'biostar' { 'biostar.com.tw' } 'dell|alienware' { 'dell.com' } 'hp|hewlett' { 'hp.com' } 'lenovo' { 'lenovo.com' }
            'acer' { 'acer.com' } 'nzxt' { 'nzxt.com' } default { $null }
        }
        $shortMaker = ($maker -replace '(?i)\s*(technology|computer|international|co\.?,?|ltd\.?|inc\.?|corporation|corp\.?)', '').Trim(' ,.')
        $query = if ($domain) { "site:$domain $($bb.Product) support drivers BIOS" } else { "$shortMaker $($bb.Product) motherboard support drivers BIOS" }
        $chipsetUrl = if ($cpu.Manufacturer -match 'Intel') { 'https://www.intel.com/content/www/us/en/support/detect.html' } else { 'https://www.amd.com/en/support/download/drivers.html' }
        if ($cpu.Manufacturer -match 'AMD' -and $bb.Product -match '\b([ABX])(\d)(\d{2})(E?)\b') {
            $socket = if ([int]$Matches[2] -ge 6) { 'am5' } else { 'am4' }
            $exact = "$amdBase/chipsets/$socket/$($Matches[1].ToLower())$($Matches[2])$($Matches[3])$($Matches[4].ToLower()).html"
            if (Test-Url $exact) { $chipsetUrl = $exact }
        }
        $board = [pscustomobject]@{
            Name        = "$shortMaker $($bb.Product)".Trim()
            Bios        = $bios.SMBIOSBIOSVersion
            BiosDate    = if ($bios.ReleaseDate) { [datetime]$bios.ReleaseDate } else { $null }
            SupportUrl  = 'https://www.bing.com/search?q=' + [uri]::EscapeDataString($query)
            ChipsetUrl  = $chipsetUrl
            ChipsetName = if ($cpu.Manufacturer -match 'Intel') { 'Intel' } else { 'AMD' }
        }
        $sync.Result = @{ Info = $info; Gpus = @($gpus); Board = $board }
    } -OnComplete {
        if (-not $sync.Result) { return }
        Show-Hardware $sync.Result.Gpus $sync.Result.Board
        $info = $sync.Result.Info
        $ui.InfoPanel.Children.Clear()
        foreach ($k in $info.Keys) {
            $card = New-Object System.Windows.Controls.Border
            $card.Style = $window.FindResource('Card')
            $card.Width = 345
            $stack = New-Object System.Windows.Controls.StackPanel
            $label = New-Object System.Windows.Controls.TextBlock
            $label.Text = $k.ToUpper(); $label.FontSize = 11; $label.Style = $window.FindResource('Muted')
            $value = New-Object System.Windows.Controls.TextBlock
            $value.Text = $info[$k]; $value.FontSize = 14; $value.TextWrapping = 'Wrap'
            $value.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0)
            [void]$stack.Children.Add($label); [void]$stack.Children.Add($value)
            $card.Child = $stack
            [void]$ui.InfoPanel.Children.Add($card)
        }
    }
}

# Header
$ui.BtnExport.Add_Click({
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = 'Peak config (*.json)|*.json'; $dlg.FileName = 'peak-config.json'
    if (-not $dlg.ShowDialog()) { return }
    [ordered]@{
        Apps     = @((Get-Checked $AppChecks) | ForEach-Object Tag)
        Tweaks   = @((Get-Checked $TweakChecks) | ForEach-Object Tag)
        Features = @((Get-Checked $FeatureChecks) | ForEach-Object { $_.Tag.Name })
    } | ConvertTo-Json | Set-Content -Path $dlg.FileName -Encoding UTF8
    Write-Log "Config exported to $($dlg.FileName)"
})
$ui.BtnImport.Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'Peak config (*.json)|*.json'
    if (-not $dlg.ShowDialog()) { return }
    try {
        $cfg = Get-Content $dlg.FileName -Raw | ConvertFrom-Json
        foreach ($cb in $AppChecks) { $cb.IsChecked = @($cfg.Apps) -contains $cb.Tag }
        foreach ($cb in $TweakChecks) { $cb.IsChecked = @($cfg.Tweaks) -contains $cb.Tag }
        foreach ($cb in $FeatureChecks) { $cb.IsChecked = @($cfg.Features) -contains $cb.Tag.Name }
        Write-Log "Config imported from $($dlg.FileName)"
    } catch { Write-Log "Import failed: $($_.Exception.Message)" 'ERROR' }
})

# Home
$ui.BtnQuickRestore.Add_Click({ Start-Tweaks @($TweakMap['RestorePoint']) $false })
$ui.BtnQuickTemp.Add_Click({ Start-Tweaks @($TweakMap['TempFiles']) $false })
$restartExplorer = { Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue; Write-Log 'Explorer restarted.' }
$ui.BtnQuickExplorer.Add_Click($restartExplorer)
$ui.BtnRestartExplorer.Add_Click($restartExplorer)
$ui.BtnQuickRefresh.Add_Click({ Start-InfoRefresh })
$ui.BtnOpenData.Add_Click({ Start-Process explorer.exe $DataDir })

# Install
$ui.TxtSearch.Add_TextChanged({
    $q = $ui.TxtSearch.Text.Trim()
    $ui.TxtSearchHint.Visibility = if ($q) { 'Hidden' } else { 'Visible' }
    foreach ($card in $AppCards) {
        $any = $false
        foreach ($cb in @($card.Child.Children | Where-Object { $_ -is [System.Windows.Controls.CheckBox] })) {
            $match = -not $q -or $cb.Content -like "*$q*" -or $cb.Tag -like "*$q*"
            $cb.Visibility = if ($match) { 'Visible' } else { 'Collapsed' }
            if ($match) { $any = $true }
        }
        $card.Visibility = if ($any) { 'Visible' } else { 'Collapsed' }
    }
})

$ui.BtnInstall.Add_Click({
    $ids = @((Get-Checked $AppChecks) | ForEach-Object Tag)
    if (-not $ids) { [System.Windows.MessageBox]::Show('Select at least one app first.', $AppName) | Out-Null; return }
    Start-PeakJob -Title "Install $($ids.Count) app(s)" -Params @{ AppIds = $ids } -Script {
        if (-not (Test-Winget)) { return }
        $i = 0
        foreach ($id in $AppIds) {
            $i++
            Write-Log "[$i/$($AppIds.Count)] Installing $id ..."
            $r = Invoke-Exe winget.exe @('install', '--id', $id, '--exact', '--silent', '--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity') -Quiet
            switch ($r.Code) {
                0 { Write-Log '  Installed / up to date.' }
                -1978335189 { Write-Log '  Already installed, no update available.' }
                -1978335135 { Write-Log '  Already installed.' }
                default { $r.Lines | Select-Object -Last 2 | ForEach-Object { Write-Log "  $_" }; Write-Log ('  Failed (code 0x{0:X8})' -f $r.Code) 'WARN' }
            }
        }
    }
})

$ui.BtnUninstall.Add_Click({
    $ids = @((Get-Checked $AppChecks) | ForEach-Object Tag)
    if (-not $ids) { [System.Windows.MessageBox]::Show('Select at least one app first.', $AppName) | Out-Null; return }
    $ok = [System.Windows.MessageBox]::Show("Uninstall $($ids.Count) app(s)?`n`n$($ids -join "`n")", $AppName, 'YesNo', 'Warning')
    if ($ok -ne 'Yes') { return }
    Start-PeakJob -Title "Uninstall $($ids.Count) app(s)" -Params @{ AppIds = $ids } -Script {
        if (-not (Test-Winget)) { return }
        foreach ($id in $AppIds) {
            Write-Log "Uninstalling $id ..."
            $r = Invoke-Exe winget.exe @('uninstall', '--id', $id, '--exact', '--silent', '--accept-source-agreements', '--disable-interactivity') -Quiet
            if ($r.Code -eq 0) { Write-Log '  Removed.' } else { $r.Lines | Select-Object -Last 1 | ForEach-Object { Write-Log "  $_" 'WARN' } }
        }
    }
})

$ui.BtnUpgradeAll.Add_Click({
    Start-PeakJob -Title 'Upgrade all apps' -Script {
        if (-not (Test-Winget)) { return }
        Invoke-Exe winget.exe @('upgrade', '--all', '--silent', '--include-unknown', '--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity') | Out-Null
    }
})

$ui.BtnSelectInstalled.Add_Click({
    Start-PeakJob -Title 'Detect installed apps' -Script {
        if (-not (Test-Winget)) { return }
        $tmp = Join-Path $env:TEMP 'peak-winget-export.json'
        Invoke-Exe winget.exe @('export', '-o', $tmp, '--accept-source-agreements', '--disable-interactivity') -Quiet | Out-Null
        if (Test-Path $tmp) {
            $j = Get-Content $tmp -Raw | ConvertFrom-Json
            $sync.Result = @($j.Sources | ForEach-Object { $_.Packages.PackageIdentifier })
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    } -OnComplete {
        if (-not $sync.Result) { return }
        $n = 0
        foreach ($cb in $AppChecks) { $cb.IsChecked = $sync.Result -contains $cb.Tag; if ($cb.IsChecked) { $n++ } }
        Write-Log "$n app(s) from the catalog are installed and now selected."
    }
})
$ui.BtnClearApps.Add_Click({ foreach ($cb in $AppChecks) { $cb.IsChecked = $false } })

# Tweaks
foreach ($name in 'Standard', 'Minimal', 'Gaming') {
    $ui["BtnPreset$name"].Tag = $name
    $ui["BtnPreset$name"].Add_Click({ param($s, $e); $ids = $Presets[$s.Tag]; foreach ($cb in $TweakChecks) { $cb.IsChecked = $ids -contains $cb.Tag } })
}
$ui.BtnPresetClear.Add_Click({ foreach ($cb in $TweakChecks) { $cb.IsChecked = $false } })
$ui.BtnRunTweaks.Add_Click({ Start-Tweaks @((Get-Checked $TweakChecks) | ForEach-Object { $TweakMap[$_.Tag] }) $false })
$ui.BtnUndoTweaks.Add_Click({ Start-Tweaks @((Get-Checked $TweakChecks) | ForEach-Object { $TweakMap[$_.Tag] }) $true })

# Config
$ui.BtnInstallFeatures.Add_Click({
    $ids = @((Get-Checked $FeatureChecks) | ForEach-Object { $_.Tag.Ids })
    if (-not $ids) { [System.Windows.MessageBox]::Show('Select at least one feature first.', $AppName) | Out-Null; return }
    Start-PeakJob -Title 'Install Windows features' -Params @{ FeatureIds = $ids } -Script {
        $restart = $false
        foreach ($f in $FeatureIds) {
            Write-Log "Enabling $f ..."
            try {
                $r = Enable-WindowsOptionalFeature -Online -FeatureName $f -All -NoRestart -ErrorAction Stop -WarningAction SilentlyContinue
                if ($r.RestartNeeded) { $restart = $true }
                Write-Log '  Enabled.'
            } catch { Write-Log "  $($_.Exception.Message)" 'WARN' }
        }
        if ($restart) { Write-Log 'Restart your PC to finish installing features.' }
    }
})

$ui.BtnFixNetwork.Add_Click({
    Start-PeakJob -Title 'Reset network stack' -Script {
        Invoke-Exe netsh.exe @('winsock', 'reset') | Out-Null
        Invoke-Exe netsh.exe @('int', 'ip', 'reset') -Quiet | Out-Null
        Invoke-Exe ipconfig.exe @('/flushdns') | Out-Null
        Invoke-Exe ipconfig.exe @('/release') -Quiet | Out-Null
        Invoke-Exe ipconfig.exe @('/renew') -Quiet | Out-Null
        Write-Log 'Network reset complete. Restart your PC.'
    }
})
$ui.BtnFixUpdate.Add_Click({
    Start-PeakJob -Title 'Reset Windows Update' -Script {
        $svcs = 'wuauserv', 'bits', 'cryptsvc', 'msiserver'
        $svcs | ForEach-Object { Stop-Service $_ -Force -ErrorAction SilentlyContinue }
        foreach ($d in "$env:SystemRoot\SoftwareDistribution", "$env:SystemRoot\System32\catroot2") {
            if (-not (Test-Path $d)) { continue }
            Remove-Item "$d.old" -Recurse -Force -ErrorAction SilentlyContinue
            try { Rename-Item $d "$(Split-Path $d -Leaf).old" -Force -ErrorAction Stop; Write-Log "  Reset $d" }
            catch { Write-Log "  Could not reset ${d}: $($_.Exception.Message)" 'WARN' }
        }
        $svcs | ForEach-Object { Start-Service $_ -ErrorAction SilentlyContinue }
        Write-Log 'Windows Update components reset. Check for updates again.'
    }
})
$ui.BtnFixSfc.Add_Click({
    Start-PeakJob -Title 'Repair system files' -Script {
        Write-Log 'DISM /RestoreHealth (can take 10-20 minutes)...'
        Invoke-Exe DISM.exe @('/Online', '/Cleanup-Image', '/RestoreHealth') | Out-Null
        Write-Log 'sfc /scannow...'
        Invoke-Exe sfc.exe @('/scannow') | Out-Null
    }
})
$ui.BtnFixComponent.Add_Click({
    Start-PeakJob -Title 'Clean component store' -Script { Invoke-Exe DISM.exe @('/Online', '/Cleanup-Image', '/StartComponentCleanup') | Out-Null }
})
$ui.BtnFixWinget.Add_Click({
    Start-PeakJob -Title 'Reset winget sources' -Script {
        if (-not (Test-Winget)) { return }
        Invoke-Exe winget.exe @('source', 'reset', '--force') | Out-Null
        Invoke-Exe winget.exe @('source', 'update') | Out-Null
    }
})

$ui.BtnApplyDns.Add_Click({
    $name = [string]$ui.CmbDns.SelectedItem
    Start-PeakJob -Title "Set DNS: $name" -Params @{ DnsName = $name; DnsServers = $DnsProviders[$name] } -Script {
        $adapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.HardwareInterface }
        if (-not $adapters) { Write-Log 'No connected physical network adapters found.' 'WARN'; return }
        foreach ($a in $adapters) {
            try {
                if ($DnsServers) { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses $DnsServers -ErrorAction Stop }
                else { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ResetServerAddresses -ErrorAction Stop }
                Write-Log "  $($a.Name): $DnsName"
            } catch { Write-Log "  $($a.Name): $($_.Exception.Message)" 'WARN' }
        }
        Clear-DnsClientCache
    }
})

# Drivers (Windows Update catalog)
$DriverChecks = New-Object System.Collections.Generic.List[object]
$ui.BtnScanDrivers.Add_Click({
    Start-PeakJob -Title 'Scan for driver updates' -Script {
        try {
            $session = New-Object -ComObject Microsoft.Update.Session
            $found = $session.CreateUpdateSearcher().Search("IsInstalled=0 and Type='Driver' and IsHidden=0").Updates
        } catch {
            Write-Log "Windows Update scan failed: $($_.Exception.Message). If you disabled updates, set Updates to Default or Security first." 'ERROR'
            return
        }
        $sync.Result = @(foreach ($u in $found) {
            [pscustomobject]@{
                Id = $u.Identity.UpdateID; Title = $u.Title; Class = "$($u.DriverClass)"; Provider = $u.DriverProvider
                Date = $u.DriverVerDate; SizeMB = [math]::Round($u.MaxDownloadSize / 1MB, 1)
            }
        })
        Write-Log "$($sync.Result.Count) driver update(s) available for this PC."
        if (-not $sync.Result.Count -and (Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'ExcludeWUDriversInQualityUpdate') -eq 1) {
            Write-Log 'Note: the "Security Updates Only" policy hides drivers from Windows Update. Use the vendor buttons above instead.'
        }
    } -OnComplete {
        # $null means the scan itself failed (already logged); an empty array means nothing to update.
        if ($null -eq $sync.Result) { return }
        $ui.DriverList.Children.Clear(); $DriverChecks.Clear()
        $list = @($sync.Result)
        if (-not $list) {
            [void]$ui.DriverList.Children.Add((New-TextLine 'No driver updates found - everything Windows Update knows about is current.' -Color '#5FD38D'))
            $ui.BtnInstallDrivers.IsEnabled = $false
            return
        }
        foreach ($d in $list) {
            $panel = New-Object System.Windows.Controls.StackPanel
            [void]$panel.Children.Add((New-TextLine $d.Title))
            $isGpu = $d.Class -match 'Display'
            $meta = '{0} - {1} - {2:d MMM yyyy} - {3} MB{4}' -f $d.Class, $d.Provider, $d.Date, $d.SizeMB, $(if ($isGpu) { ' - graphics: prefer the vendor driver' } else { '' })
            [void]$panel.Children.Add((New-TextLine $meta -Muted))
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Content = $panel; $cb.Tag = $d.Id; $cb.IsChecked = -not $isGpu
            $cb.Margin = [System.Windows.Thickness]::new(0, 2, 0, 6)
            [void]$ui.DriverList.Children.Add($cb)
            $DriverChecks.Add($cb)
        }
        $ui.BtnInstallDrivers.IsEnabled = $true
    }
})
$ui.BtnInstallDrivers.Add_Click({
    $ids = @((Get-Checked $DriverChecks) | ForEach-Object Tag)
    if (-not $ids) { [System.Windows.MessageBox]::Show('Select at least one driver first.', $AppName) | Out-Null; return }
    Start-PeakJob -Title "Install $($ids.Count) driver(s)" -Params @{ DriverIds = $ids } -Script {
        $session = New-Object -ComObject Microsoft.Update.Session
        $found = $session.CreateUpdateSearcher().Search("IsInstalled=0 and Type='Driver' and IsHidden=0").Updates
        $coll = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($u in $found) {
            if ($DriverIds -notcontains $u.Identity.UpdateID) { continue }
            if (-not $u.EulaAccepted) { $u.AcceptEula() }
            [void]$coll.Add($u)
        }
        if ($coll.Count -eq 0) { Write-Log 'Those drivers are no longer pending.'; return }
        Write-Log "Downloading $($coll.Count) driver(s)..."
        $dl = $session.CreateUpdateDownloader(); $dl.Updates = $coll; [void]$dl.Download()
        Write-Log 'Installing...'
        $inst = $session.CreateUpdateInstaller(); $inst.Updates = $coll
        $res = $inst.Install()
        for ($i = 0; $i -lt $coll.Count; $i++) {
            $code = $res.GetUpdateResult($i).ResultCode
            $state = @{ 2 = 'installed'; 3 = 'installed with errors'; 4 = 'FAILED'; 5 = 'aborted' }[[int]$code]
            Write-Log "  $($coll.Item($i).Title): $state"
        }
        if ($res.RebootRequired) { Write-Log 'Restart your PC to finish installing drivers.' }
    } -OnComplete { $ui.BtnScanDrivers.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
})

# Updates
$updateScript = {
    $wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $medic = 'HKLM:\SYSTEM\CurrentControlSet\Services\WaaSMedicSvc'
    if ($UpdateMode -eq 'Disable') {
        Set-RegValue "$wu\AU" 'NoAutoUpdate' 1
        Set-RegValue "$wu\AU" 'AUOptions' 1
        Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config' 'DODownloadMode' 0
        Set-ServiceStartup 'wuauserv' 'Disabled'
        Set-ServiceStartup 'UsoSvc' 'Disabled'
        try { Set-RegValue $medic 'Start' 4 } catch { Write-Log '  WaaSMedicSvc is protected and may re-enable updates.' 'WARN' }
        Write-Log 'Windows Update disabled. Use "Default Settings" to turn it back on.'
        return
    }
    # Default and Security both start from a clean slate.
    Remove-Item $wu -Recurse -Force -ErrorAction SilentlyContinue
    Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config' 'DODownloadMode' '<Remove>'
    Set-ServiceStartup 'wuauserv' 'Manual'
    Set-ServiceStartup 'UsoSvc' 'AutomaticDelayedStart'
    try { Set-RegValue $medic 'Start' 3 } catch { }
    if ($UpdateMode -eq 'Security') {
        Set-RegValue $wu 'DeferFeatureUpdates' 1
        Set-RegValue $wu 'DeferFeatureUpdatesPeriodInDays' 365
        Set-RegValue $wu 'DeferQualityUpdates' 1
        Set-RegValue $wu 'DeferQualityUpdatesPeriodInDays' 4
        Set-RegValue $wu 'ExcludeWUDriversInQualityUpdate' 1
        Set-RegValue "$wu\AU" 'NoAutoRebootWithLoggedOnUsers' 1
        Write-Log 'Security-first update policy applied.'
    } else {
        Write-Log 'Windows Update restored to default settings.'
    }
}
$ui.BtnUpdDefault.Add_Click({ Start-PeakJob -Title 'Updates: default' -Params @{ UpdateMode = 'Default' } -Script $updateScript })
$ui.BtnUpdSecurity.Add_Click({ Start-PeakJob -Title 'Updates: security only' -Params @{ UpdateMode = 'Security' } -Script $updateScript })
$ui.BtnUpdDisable.Add_Click({
    $ok = [System.Windows.MessageBox]::Show("This stops ALL Windows updates, including security patches.`n`nContinue?", $AppName, 'YesNo', 'Warning')
    if ($ok -eq 'Yes') { Start-PeakJob -Title 'Updates: disable all' -Params @{ UpdateMode = 'Disable' } -Script $updateScript }
})

# Log / window
$ui.BtnClearLog.Add_Click({ $ui.LogBox.Clear() })
$window.Add_Closing({
    param($s, $e)
    if ($sync.Busy) {
        $ok = [System.Windows.MessageBox]::Show("'$($sync.Job.Title)' is still running. Closing now may leave it half-finished.`n`nClose anyway?", $AppName, 'YesNo', 'Warning')
        if ($ok -ne 'Yes') { $e.Cancel = $true; return }
    }
    Confirm-DraftSaved
    if ($script:MacroEngineReady) { [Peak.MacroEngine]::Shutdown() }
})
#endregion

#region Macros: record / edit / play keyboard and mouse input ----------------------------
# Compiled on first use only, so the app starts as fast as before.
$MacroSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

namespace Peak
{
    public class MacroEvent
    {
        public int T { get; set; }          // Delay steps: milliseconds to wait. Recorded steps: ms since the previous one.
        public string Type { get; set; }    // KeyDown, KeyUp, MouseDown, MouseUp, Move, Wheel, Delay
        public int Key { get; set; }        // virtual-key code
        public string Button { get; set; }  // Left, Right, Middle, X1, X2
        public int X { get; set; }
        public int Y { get; set; }
        public int Delta { get; set; }
        public bool Pos { get; set; }       // mouse button steps: move to X,Y first
    }

    public class Macro
    {
        public Macro() { Name = ""; Repeat = 1; Speed = 1.0; Events = new List<MacroEvent>(); }
        public string Name { get; set; }
        public int Repeat { get; set; }     // 0 = until stopped
        public double Speed { get; set; }
        public List<MacroEvent> Events { get; set; }
    }

    public static class MacroEngine
    {
        delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

        [StructLayout(LayoutKind.Sequential)] struct POINT { public int x; public int y; }
        [StructLayout(LayoutKind.Sequential)] struct KBDLLHOOKSTRUCT { public uint vkCode; public uint scanCode; public uint flags; public uint time; public IntPtr extra; }
        [StructLayout(LayoutKind.Sequential)] struct MSLLHOOKSTRUCT { public POINT pt; public uint mouseData; public uint flags; public uint time; public IntPtr extra; }
        [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public POINT pt; }
        [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr extra; }
        [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr extra; }
        [StructLayout(LayoutKind.Explicit)] struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
        [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public INPUTUNION u; }

        [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetWindowsHookEx(int idHook, HookProc fn, IntPtr hMod, uint threadId);
        [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
        [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook, int nCode, IntPtr wParam, IntPtr lParam);
        [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string name);
        [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
        [DllImport("user32.dll")] static extern int GetMessage(out MSG msg, IntPtr hwnd, uint min, uint max);
        [DllImport("user32.dll")] static extern bool PeekMessage(out MSG msg, IntPtr hwnd, uint min, uint max, uint remove);
        [DllImport("user32.dll")] static extern bool PostThreadMessage(uint threadId, uint msg, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint count, INPUT[] inputs, int size);
        [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint mapType);
        [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);

        const uint WM_QUIT = 0x0012, WM_MOUSE_HOOK_ON = 0x8001, WM_MOUSE_HOOK_OFF = 0x8002;

        static readonly HookProc keyboardProc = KeyboardProc;   // kept alive so the GC never collects them
        static readonly HookProc mouseProc = MouseProc;
        static readonly object gate = new object();
        static readonly Stopwatch clock = new Stopwatch();
        static readonly HashSet<int> heldHotkeys = new HashSet<int>();
        static readonly HashSet<int> extendedKeys = new HashSet<int> { 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x2C, 0x2D, 0x2E, 0x5B, 0x5C, 0x5D, 0x6F, 0x90, 0xA3, 0xA5 };
        static IntPtr keyboardHook = IntPtr.Zero, mouseHook = IntPtr.Zero;
        static Thread hookThread;
        static uint hookThreadId;
        static Dictionary<int, Macro> bindings = new Dictionary<int, Macro>();
        static List<MacroEvent> recording = new List<MacroEvent>();
        static MacroEvent[] finished;
        static long lastEventMs, lastMoveMs;
        static volatile bool stopRequested;
        static volatile bool recordMoves, recordClicks, clickPositions;

        public static int StopRecordKey = 0x77;   // F8
        public static volatile bool Enabled;
        public static volatile bool IsRecording;
        public static volatile bool IsPlaying;
        public static volatile string PlayingName = "";
        public static bool HooksActive { get { return keyboardHook != IntPtr.Zero; } }
        public static int RecordedCount { get { lock (gate) { return recording.Count; } } }

        // Hooks live on their own thread with its own message loop, so a busy UI can never lag system input.
        static void EnsureHookThread()
        {
            if (hookThread != null) return;
            var ready = new ManualResetEvent(false);
            hookThread = new Thread(delegate ()
            {
                MSG msg;
                PeekMessage(out msg, IntPtr.Zero, 0, 0, 0);   // creates this thread's message queue
                hookThreadId = GetCurrentThreadId();
                IntPtr module = GetModuleHandle(null);
                keyboardHook = SetWindowsHookEx(13, keyboardProc, module, 0);
                ready.Set();
                while (GetMessage(out msg, IntPtr.Zero, 0, 0) > 0)
                {
                    if (msg.message == WM_MOUSE_HOOK_ON && mouseHook == IntPtr.Zero) mouseHook = SetWindowsHookEx(14, mouseProc, module, 0);
                    else if (msg.message == WM_MOUSE_HOOK_OFF && mouseHook != IntPtr.Zero) { UnhookWindowsHookEx(mouseHook); mouseHook = IntPtr.Zero; }
                }
                if (mouseHook != IntPtr.Zero) { UnhookWindowsHookEx(mouseHook); mouseHook = IntPtr.Zero; }
                if (keyboardHook != IntPtr.Zero) { UnhookWindowsHookEx(keyboardHook); keyboardHook = IntPtr.Zero; }
            });
            hookThread.IsBackground = true;
            hookThread.Start();
            ready.WaitOne();
        }

        static void StopHookThreadIfIdle()
        {
            if (Enabled || IsRecording || hookThread == null) return;
            Thread t = hookThread;
            hookThread = null;
            PostThreadMessage(hookThreadId, WM_QUIT, IntPtr.Zero, IntPtr.Zero);
            if (Thread.CurrentThread != t) t.Join(2000);
        }

        public static void Enable() { Enabled = true; EnsureHookThread(); }
        public static void Disable() { Enabled = false; StopHookThreadIfIdle(); }
        public static void Shutdown() { Enabled = false; StopPlayback(); if (IsRecording) EndRecording(false); StopHookThreadIfIdle(); }

        public static void SetBindings(int[] keys, Macro[] macros)
        {
            var map = new Dictionary<int, Macro>();
            for (int i = 0; i < keys.Length && i < macros.Length; i++) if (keys[i] > 0) map[keys[i]] = macros[i];
            bindings = map;
        }

        public static void StartRecording(bool moves, bool clicks, bool positions)
        {
            lock (gate) { recording = new List<MacroEvent>(); finished = null; lastEventMs = 0; lastMoveMs = 0; clock.Restart(); }
            recordMoves = moves; recordClicks = clicks; clickPositions = positions;
            EnsureHookThread();
            IsRecording = true;
            // The mouse hook only exists while recording mouse input, so games never get extra mouse latency.
            if (moves || clicks) PostThreadMessage(hookThreadId, WM_MOUSE_HOOK_ON, IntPtr.Zero, IntPtr.Zero);
        }

        // dropLastClick: recording was stopped by clicking a button in this app, so drop that click.
        public static void EndRecording(bool dropLastClick)
        {
            if (!IsRecording) return;
            IsRecording = false;
            PostThreadMessage(hookThreadId, WM_MOUSE_HOOK_OFF, IntPtr.Zero, IntPtr.Zero);
            lock (gate)
            {
                if (dropLastClick)
                {
                    int i = recording.FindLastIndex(e => e.Type == "MouseDown" && e.Button == "Left");
                    if (i >= 0) recording.RemoveRange(i, recording.Count - i);
                }
                while (recording.Count > 0 && recording[recording.Count - 1].Type == "Move") recording.RemoveAt(recording.Count - 1);
                if (recording.Count > 0) recording[0].T = 0;
                finished = recording.ToArray();
            }
            StopHookThreadIfIdle();
        }

        public static MacroEvent[] TakeRecording() { lock (gate) { var f = finished; finished = null; return f; } }

        static void Record(MacroEvent e)
        {
            lock (gate)
            {
                long now = clock.ElapsedMilliseconds;
                if (e.Type == "Move") { if (now - lastMoveMs < 8) return; lastMoveMs = now; }
                e.T = (int)(now - lastEventMs);
                lastEventMs = now;
                recording.Add(e);
            }
        }

        static IntPtr KeyboardProc(int nCode, IntPtr wParam, IntPtr lParam)
        {
            if (nCode >= 0)
            {
                var k = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
                int msg = wParam.ToInt32();
                bool down = msg == 0x100 || msg == 0x104;
                int vk = (int)k.vkCode;
                if ((k.flags & 0x10) == 0)   // ignore injected input, including our own playback
                {
                    if (IsRecording)
                    {
                        if (vk == StopRecordKey) { if (down) EndRecording(false); return (IntPtr)1; }
                        Record(new MacroEvent { Type = down ? "KeyDown" : "KeyUp", Key = vk });
                    }
                    else if (Enabled)
                    {
                        Macro m;
                        if (bindings.TryGetValue(vk, out m))
                        {
                            if (!down) heldHotkeys.Remove(vk);
                            else if (heldHotkeys.Add(vk)) { if (IsPlaying) StopPlayback(); else Play(m); }
                            return (IntPtr)1;   // the hotkey itself is not passed on
                        }
                    }
                }
            }
            return CallNextHookEx(IntPtr.Zero, nCode, wParam, lParam);
        }

        static IntPtr MouseProc(int nCode, IntPtr wParam, IntPtr lParam)
        {
            if (nCode >= 0 && IsRecording)
            {
                var m = (MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(MSLLHOOKSTRUCT));
                if ((m.flags & 0x01) == 0)
                {
                    var e = new MacroEvent { X = m.pt.x, Y = m.pt.y, Pos = clickPositions };
                    int hi = (short)((m.mouseData >> 16) & 0xFFFF);
                    switch (wParam.ToInt32())
                    {
                        case 0x200: e.Type = recordMoves ? "Move" : null; break;
                        case 0x201: e.Type = "MouseDown"; e.Button = "Left"; break;
                        case 0x202: e.Type = "MouseUp"; e.Button = "Left"; break;
                        case 0x204: e.Type = "MouseDown"; e.Button = "Right"; break;
                        case 0x205: e.Type = "MouseUp"; e.Button = "Right"; break;
                        case 0x207: e.Type = "MouseDown"; e.Button = "Middle"; break;
                        case 0x208: e.Type = "MouseUp"; e.Button = "Middle"; break;
                        case 0x20B: e.Type = "MouseDown"; e.Button = hi == 1 ? "X1" : "X2"; break;
                        case 0x20C: e.Type = "MouseUp"; e.Button = hi == 1 ? "X1" : "X2"; break;
                        case 0x20A: e.Type = "Wheel"; e.Delta = hi; break;
                    }
                    if (e.Type != null && e.Type != "Move" && !recordClicks) e.Type = null;
                    if (e.Type != null) Record(e);
                }
            }
            return CallNextHookEx(IntPtr.Zero, nCode, wParam, lParam);
        }

        public static void Play(Macro macro)
        {
            if (IsPlaying || macro == null || macro.Events == null || macro.Events.Count == 0) return;
            MacroEvent[] steps = macro.Events.ToArray();
            int repeat = macro.Repeat;
            double speed = macro.Speed > 0 ? macro.Speed : 1.0;
            stopRequested = false;
            IsPlaying = true;
            PlayingName = macro.Name ?? "";
            var t = new Thread(delegate ()
            {
                var keys = new HashSet<int>();
                var buttons = new HashSet<string>();
                try
                {
                    for (int r = 0; (repeat <= 0 || r < repeat) && !stopRequested; r++)
                    {
                        foreach (MacroEvent e in steps)
                        {
                            if (!Wait((int)(e.T / speed))) break;
                            Send(e, keys, buttons);
                        }
                        Thread.Sleep(1);
                    }
                }
                finally
                {
                    // Never leave a key or button stuck down.
                    foreach (int vk in keys) SendKey(vk, false);
                    foreach (string b in buttons) SendButton(b, false);
                    IsPlaying = false;
                    PlayingName = "";
                }
            });
            t.IsBackground = true;
            t.Start();
        }

        public static void StopPlayback() { stopRequested = true; }

        static bool Wait(int ms)
        {
            var sw = Stopwatch.StartNew();
            while (!stopRequested)
            {
                long left = ms - sw.ElapsedMilliseconds;
                if (left <= 0) return true;
                Thread.Sleep((int)Math.Min(left, 10));
            }
            return false;
        }

        static void Send(MacroEvent e, HashSet<int> keys, HashSet<string> buttons)
        {
            switch (e.Type)
            {
                case "KeyDown": SendKey(e.Key, true); keys.Add(e.Key); break;
                case "KeyUp": SendKey(e.Key, false); keys.Remove(e.Key); break;
                case "Move": MoveTo(e.X, e.Y); break;
                case "MouseDown": if (e.Pos) MoveTo(e.X, e.Y); SendButton(e.Button, true); buttons.Add(e.Button); break;
                case "MouseUp": if (e.Pos) MoveTo(e.X, e.Y); SendButton(e.Button, false); buttons.Remove(e.Button); break;
                case "Wheel": SendMouse(0, 0, unchecked((uint)e.Delta), 0x0800); break;
            }
        }

        static void SendKey(int vk, bool down)
        {
            var input = new INPUT { type = 1 };
            ushort scan = (ushort)MapVirtualKey((uint)vk, 0);
            uint flags = down ? 0u : 0x0002u;
            if (scan != 0) flags |= 0x0008;   // scan codes are what DirectInput / raw-input games read
            if (extendedKeys.Contains(vk)) flags |= 0x0001;
            input.u.ki.wVk = (ushort)vk;
            input.u.ki.wScan = scan;
            input.u.ki.dwFlags = flags;
            SendInput(1, new[] { input }, Marshal.SizeOf(typeof(INPUT)));
        }

        static void SendButton(string button, bool down)
        {
            uint flags, data = 0;
            switch (button)
            {
                case "Left": flags = down ? 0x0002u : 0x0004u; break;
                case "Right": flags = down ? 0x0008u : 0x0010u; break;
                case "Middle": flags = down ? 0x0020u : 0x0040u; break;
                case "X1": flags = down ? 0x0080u : 0x0100u; data = 1; break;
                case "X2": flags = down ? 0x0080u : 0x0100u; data = 2; break;
                default: return;
            }
            SendMouse(0, 0, data, flags);
        }

        static void MoveTo(int x, int y)
        {
            int vx = GetSystemMetrics(76), vy = GetSystemMetrics(77), vw = GetSystemMetrics(78), vh = GetSystemMetrics(79);
            if (vw < 2 || vh < 2) return;
            int nx = (int)(((long)(x - vx) * 65535) / (vw - 1));
            int ny = (int)(((long)(y - vy) * 65535) / (vh - 1));
            SendMouse(nx, ny, 0, 0x0001 | 0x8000 | 0x4000);   // move, absolute, whole virtual desktop
        }

        static void SendMouse(int dx, int dy, uint data, uint flags)
        {
            var input = new INPUT { type = 0 };
            input.u.mi.dx = dx;
            input.u.mi.dy = dy;
            input.u.mi.mouseData = data;
            input.u.mi.dwFlags = flags;
            SendInput(1, new[] { input }, Marshal.SizeOf(typeof(INPUT)));
        }
    }
}
'@

$MacroFile = Join-Path $DataDir 'macros.json'
$MacroEngineReady = $false
$MacroStepTypes = 'KeyDown', 'KeyUp', 'MouseDown', 'MouseUp', 'Move', 'Wheel', 'Delay'
$MacroButtons = 'Left', 'Right', 'Middle', 'X1', 'X2'
$MacroButtonNames = @{ Left = '{LMouse}'; Right = '{RMouse}'; Middle = '{MMouse}'; X1 = '{Mouse4}'; X2 = '{Mouse5}' }
$StopRecordVk = 0x77   # F8
$Invariant = [System.Globalization.CultureInfo]::InvariantCulture
$MacroSpeeds = [ordered]@{ '0.25x' = 0.25; '0.5x' = 0.5; '1x' = 1.0; '1.5x' = 1.5; '2x' = 2.0; '4x' = 4.0 }
$OemNames = @{ 0xBA = ';'; 0xBB = '='; 0xBC = ','; 0xBD = '-'; 0xBE = '.'; 0xBF = '/'; 0xC0 = '`'; 0xDB = '['; 0xDC = '\'; 0xDD = ']'; 0xDE = "'" }

# Hotkey names used by v1.2.0 macro files.
$LegacyHotkeys = @{}
foreach ($i in 1..24) { $LegacyHotkeys["F$i"] = 0x6F + $i }
foreach ($i in 0..9) { $LegacyHotkeys["Numpad $i"] = 0x60 + $i }
$LegacyHotkeys['Numpad *'] = 0x6A; $LegacyHotkeys['Numpad +'] = 0x6B; $LegacyHotkeys['Numpad -'] = 0x6D; $LegacyHotkeys['Numpad /'] = 0x6F
$LegacyHotkeys['Numpad .'] = 0x6E; $LegacyHotkeys['Insert'] = 0x2D; $LegacyHotkeys['Home'] = 0x24; $LegacyHotkeys['Page Up'] = 0x21
$LegacyHotkeys['Delete'] = 0x2E; $LegacyHotkeys['End'] = 0x23; $LegacyHotkeys['Page Down'] = 0x22; $LegacyHotkeys['Pause'] = 0x13; $LegacyHotkeys['Scroll Lock'] = 0x91

function Initialize-MacroEngine {
    if ($script:MacroEngineReady) { return $true }
    try {
        if (-not ('Peak.MacroEngine' -as [type])) { Add-Type -TypeDefinition $MacroSource -ErrorAction Stop }
        $script:MacroEngineReady = $true
    } catch { Write-Log "Macro engine failed to load: $($_.Exception.Message)" 'ERROR' }
    $script:MacroEngineReady
}

function Get-KeyName([int]$Vk) {
    if ($Vk -le 0) { return '(none)' }
    if ($OemNames.ContainsKey($Vk)) { return $OemNames[$Vk] }
    if ($Vk -ge 0x41 -and $Vk -le 0x5A) { return [string][char]($Vk + 32) }   # a-z
    if ($Vk -ge 0x30 -and $Vk -le 0x39) { return [string][char]$Vk }          # 0-9
    if ($Vk -ge 0x60 -and $Vk -le 0x69) { return "Numpad $($Vk - 0x60)" }
    $k = [System.Windows.Input.KeyInterop]::KeyFromVirtualKey($Vk)
    if ("$k" -eq 'None') { "VK $Vk" } else { "$k" }
}

function New-Step([string]$Type, [int]$T = 0, [int]$Key = 0, [string]$Button, [int]$X = 0, [int]$Y = 0, [int]$Delta = 0, [bool]$Pos = $false) {
    [pscustomobject]@{ Type = $Type; T = $T; Key = $Key; Button = $(if ($Button) { $Button } else { $null }); X = $X; Y = $Y; Delta = $Delta; Pos = $Pos }
}

function New-MacroObject([string]$Name) {
    [pscustomobject]@{ Name = $Name; HotkeyVk = 0; Repeat = 1; Speed = 1.0; Events = @() }
}

function Copy-Macro($M) {
    [pscustomobject]@{
        Name = $M.Name; HotkeyVk = $M.HotkeyVk; Repeat = $M.Repeat; Speed = $M.Speed
        Events = @(@($M.Events) | ForEach-Object { New-Step $_.Type $_.T $_.Key $_.Button $_.X $_.Y $_.Delta $_.Pos })
    }
}

function Get-UniqueMacroName([string]$Base, [int]$Except = -1) {
    $names = @(for ($i = 0; $i -lt $Macros.Count; $i++) { if ($i -ne $Except) { $Macros[$i].Name } })
    if ($names -notcontains $Base) { return $Base }
    $n = 2
    while ($names -contains "$Base ($n)") { $n++ }
    "$Base ($n)"
}

# Turns untrusted JSON (imports and the saved file) into a clean macro: only known step types and numbers survive.
# Older files stored the wait on every step; that becomes a separate Delay step.
function ConvertFrom-MacroJson($Obj) {
    $legacyPos = [bool]$Obj.MousePositions
    $steps = foreach ($e in @($Obj.Events)) {
        if (-not $e -or $MacroStepTypes -notcontains [string]$e.Type) { continue }
        $t = [math]::Min([math]::Max(0, [int]$e.T), 3600000)
        if ($e.Type -eq 'Delay') { New-Step 'Delay' $t; continue }
        if ($t -gt 0) { New-Step 'Delay' $t }
        $button = if ($MacroButtons -contains [string]$e.Button) { [string]$e.Button } else { $null }
        if ($e.Type -like 'Mouse*' -and -not $button) { continue }
        New-Step ([string]$e.Type) 0 ([math]::Min([math]::Max(0, [int]$e.Key), 254)) $button ([int]$e.X) ([int]$e.Y) ([int]$e.Delta) ([bool]$e.Pos -or ($legacyPos -and $e.Type -like 'Mouse*'))
    }
    $vk = [int]$Obj.HotkeyVk
    if (-not $vk -and $Obj.Hotkey -and $LegacyHotkeys.ContainsKey([string]$Obj.Hotkey)) { $vk = $LegacyHotkeys[[string]$Obj.Hotkey] }
    if ($vk -lt 1 -or $vk -gt 254 -or $vk -eq $StopRecordVk) { $vk = 0 }
    $repeat = if ($null -ne $Obj.Repeat) { [math]::Min([math]::Max(0, [int]$Obj.Repeat), 9999) } else { 1 }
    $speed = [double]$Obj.Speed
    [pscustomobject]@{
        Name     = if ("$($Obj.Name)".Trim()) { "$($Obj.Name)".Trim() } else { 'Imported macro' }
        HotkeyVk = $vk
        Repeat   = $repeat
        Speed    = if ($speed -ge 0.1 -and $speed -le 10) { $speed } else { 1.0 }
        Events   = @($steps)
    }
}

function ConvertTo-EngineMacro($M) {
    $em = New-Object Peak.Macro
    $em.Name = $M.Name; $em.Repeat = $M.Repeat; $em.Speed = $M.Speed
    foreach ($e in @($M.Events)) {
        $s = New-Object Peak.MacroEvent
        $s.T = $e.T; $s.Type = $e.Type; $s.Key = $e.Key; $s.Button = $e.Button; $s.X = $e.X; $s.Y = $e.Y; $s.Delta = $e.Delta; $s.Pos = $e.Pos
        $em.Events.Add($s)
    }
    $em
}

function Save-Macros {
    try { ConvertTo-Json -InputObject @{ PeakMacros = 2; Macros = @($Macros) } -Depth 6 | Set-Content -Path $MacroFile -Encoding UTF8 }
    catch { Write-Log "Could not save macros: $($_.Exception.Message)" 'ERROR' }
}

function Read-MacroFile([string]$Path) {
    $data = Get-Content -Path $Path -Raw | ConvertFrom-Json
    # Accept a full export ({ Macros: [...] }) or a single macro object.
    $items = if ($data.PSObject.Properties['Macros']) { @($data.Macros) } else { @($data) }
    @($items | Where-Object { $_ } | ForEach-Object { ConvertFrom-MacroJson $_ })
}

function Update-MacroBindings {
    if (-not $script:MacroEngineReady) { return }
    $bound = @($Macros | Where-Object { $_.HotkeyVk -gt 0 -and @($_.Events).Count -gt 0 })
    [Peak.MacroEngine]::SetBindings([int[]]@($bound | ForEach-Object { $_.HotkeyVk }), [Peak.Macro[]]@($bound | ForEach-Object { ConvertTo-EngineMacro $_ }))
}

# ---------- macro list and the editing draft (changes apply on Save, like OK/Cancel) ----------
function Update-MacroList([int]$SelectIndex = -1) {
    $script:SuppressMacroList = $true
    try {
        $ui.LstMacros.Items.Clear()
        foreach ($m in $Macros) {
            $key = if ($m.HotkeyVk) { "   [$(Get-KeyName $m.HotkeyVk)]" } else { '' }
            [void]$ui.LstMacros.Items.Add("$($m.Name)$key")
        }
        $ui.LstMacros.SelectedIndex = $SelectIndex
    } finally { $script:SuppressMacroList = $false }
}

function Set-DraftDirty([bool]$Dirty) {
    $script:DraftDirty = $Dirty
    $ui.BtnMacroSave.IsEnabled = $Dirty
    $ui.BtnMacroCancel.IsEnabled = $Dirty
}

function Open-Draft {
    $i = $ui.LstMacros.SelectedIndex
    if ($i -ge 0 -and $i -lt $Macros.Count) { $script:Draft = Copy-Macro $Macros[$i]; $script:DraftIndex = $i }
    else { $script:Draft = $null; $script:DraftIndex = -1 }
    Set-DraftDirty $false
    Show-MacroEditor
}

function Save-Draft {
    $d = $script:Draft
    if (-not $d -or $script:DraftIndex -lt 0) { return }
    $d.Name = Get-UniqueMacroName ($(if ($d.Name.Trim()) { $d.Name.Trim() } else { 'Macro' })) $script:DraftIndex
    if ($d.HotkeyVk) {
        for ($i = 0; $i -lt $Macros.Count; $i++) {
            if ($i -ne $script:DraftIndex -and $Macros[$i].HotkeyVk -eq $d.HotkeyVk) {
                $Macros[$i].HotkeyVk = 0
                Write-Log "$(Get-KeyName $d.HotkeyVk) was moved from '$($Macros[$i].Name)' to '$($d.Name)'."
            }
        }
    }
    $Macros[$script:DraftIndex] = Copy-Macro $d
    Save-Macros
    Update-MacroBindings
    Update-MacroList $script:DraftIndex
    Set-DraftDirty $false
    Show-MacroEditor
    Write-Log "Saved macro '$($d.Name)'."
}

# Asks to save unsaved edits before switching away from the current macro.
function Confirm-DraftSaved {
    if (-not ($script:DraftDirty -and $script:Draft)) { return }
    $ok = [System.Windows.MessageBox]::Show("Save your changes to '$($script:Draft.Name)'?", $AppName, 'YesNo', 'Question')
    if ($ok -eq 'Yes') { Save-Draft } else { Set-DraftDirty $false }
}

function Format-MacroStep($E) {
    $label, $action = switch ($E.Type) {
        'Delay' { [string]::Format($Invariant, '{0:0.###}', $E.T / 1000), 'Delay' }
        'KeyDown' { (Get-KeyName $E.Key), 'Hold' }
        'KeyUp' { (Get-KeyName $E.Key), 'Release' }
        'MouseDown' { $MacroButtonNames[[string]$E.Button], ('Hold' + $(if ($E.Pos) { "   at $($E.X), $($E.Y)" })) }
        'MouseUp' { $MacroButtonNames[[string]$E.Button], ('Release' + $(if ($E.Pos) { "   at $($E.X), $($E.Y)" })) }
        'Move' { '{Move}', "$($E.X), $($E.Y)" }
        'Wheel' { '{Wheel}', $(if ($E.Delta -gt 0) { 'Up' } else { 'Down' }) }
    }
    '{0,-14} {1}' -f $label, $action
}

function Show-MacroSteps([int]$Select = -1) {
    $script:LoadingMacro = $true
    try {
        $ui.LstMacroSteps.Items.Clear()
        if (-not $script:Draft) { $ui.TxtMacroSummary.Text = 'Select a macro, or click New.'; return }
        $steps = @($script:Draft.Events)
        foreach ($e in $steps) { [void]$ui.LstMacroSteps.Items.Add((Format-MacroStep $e)) }
        $ui.LstMacroSteps.SelectedIndex = [math]::Min($Select, $steps.Count - 1)
        if ($ui.LstMacroSteps.SelectedIndex -ge 0) { $ui.LstMacroSteps.ScrollIntoView($ui.LstMacroSteps.SelectedItem) }
        $ms = (@($steps | Where-Object Type -eq 'Delay') | Measure-Object T -Sum).Sum
        $ui.TxtMacroSummary.Text = [string]::Format($Invariant, '{0} steps, {1:0.##} s per run', $steps.Count, $ms / 1000) +
            $(if ($script:DraftDirty) { '  -  unsaved changes' } else { '' })
    } finally { $script:LoadingMacro = $false }
    Sync-DelayBox
}

function Show-MacroEditor {
    $d = $script:Draft
    $script:LoadingMacro = $true
    try {
        $ui.MacroEditor.IsEnabled = [bool]$d
        if (-not $d) { $ui.TxtMacroName.Text = ''; $ui.TxtMacroBound.Text = '(none)'; return }
        $ui.TxtMacroName.Text = $d.Name
        $ui.TxtMacroBound.Text = Get-KeyName $d.HotkeyVk
        $ui.RbMacroOnce.IsChecked = $d.Repeat -eq 1
        $ui.RbMacroLoop.IsChecked = $d.Repeat -eq 0
        $ui.RbMacroRepeat.IsChecked = $d.Repeat -gt 1
        if ($d.Repeat -gt 1) { $ui.TxtRepeatCount.Text = "$($d.Repeat)" }
        $ui.TxtRepeatCount.IsEnabled = $d.Repeat -gt 1
        $ui.CmbMacroSpeed.SelectedItem = @($MacroSpeeds.Keys | Where-Object { $MacroSpeeds[$_] -eq $d.Speed })[0]
        if ($ui.CmbMacroSpeed.SelectedIndex -lt 0) { $ui.CmbMacroSpeed.SelectedItem = '1x' }
    } finally { $script:LoadingMacro = $false }
    Show-MacroSteps 0
}

function Set-DraftChanged([int]$Select = $ui.LstMacroSteps.SelectedIndex) {
    Set-DraftDirty $true
    Show-MacroSteps $Select
}

# ---------- steps ----------
function Get-SelectedStepIndex {
    $i = $ui.LstMacroSteps.SelectedIndex
    if ($script:Draft -and $i -ge 0 -and $i -lt @($script:Draft.Events).Count) { $i } else { -1 }
}

function Add-MacroSteps([object[]]$New, [int]$At = -1) {
    if (-not $script:Draft -or -not $New) { return }
    $list = [System.Collections.ArrayList]@($script:Draft.Events)
    if ($At -lt 0) { $sel = Get-SelectedStepIndex; $At = if ($sel -ge 0) { $sel + 1 } else { $list.Count } }
    $At = [math]::Min($At, $list.Count)
    $list.InsertRange($At, $New)
    $script:Draft.Events = $list.ToArray()
    Set-DraftChanged ($At + $New.Count - 1)
}

function ConvertFrom-DelayText([string]$Text) {
    $v = 0.0
    if (-not [double]::TryParse($Text.Trim().Replace(',', '.'), [System.Globalization.NumberStyles]::Float, $Invariant, [ref]$v)) { return $null }
    [int][math]::Round([math]::Min([math]::Max(0.0, $v), 3600.0) * 1000)
}

# The Delay box edits the selected Delay step; otherwise it is the length used by Insert > Delay.
function Sync-DelayBox {
    $i = Get-SelectedStepIndex
    if ($i -ge 0 -and $script:Draft.Events[$i].Type -eq 'Delay') {
        $script:LoadingMacro = $true
        try { $ui.TxtDelay.Text = [string]::Format($Invariant, '{0:0.###}', $script:Draft.Events[$i].T / 1000) } finally { $script:LoadingMacro = $false }
    }
}

function Set-DelayFromBox {
    $ms = ConvertFrom-DelayText $ui.TxtDelay.Text
    $i = Get-SelectedStepIndex
    if ($null -eq $ms -or $i -lt 0 -or $script:Draft.Events[$i].Type -ne 'Delay' -or $script:Draft.Events[$i].T -eq $ms) { return }
    $script:Draft.Events[$i].T = $ms
    Set-DirtyKeepCaret
    # Update just that row without re-syncing the box, so the text being typed is left alone.
    $script:LoadingMacro = $true
    try {
        $ui.LstMacroSteps.Items[$i] = Format-MacroStep $script:Draft.Events[$i]
        $ui.LstMacroSteps.SelectedIndex = $i
    } finally { $script:LoadingMacro = $false }
}
function Set-DirtyKeepCaret { if (-not $script:DraftDirty) { Set-DraftDirty $true } }

function Step-DelayBox([double]$By) {
    $ms = ConvertFrom-DelayText $ui.TxtDelay.Text
    if ($null -eq $ms) { $ms = 0 }
    $ui.TxtDelay.Text = [string]::Format($Invariant, '{0:0.###}', [math]::Max(0.0, $ms / 1000 + $By))
}

# ---------- key capture (Bind to Key, Insert key steps) ----------
function Start-KeyCapture([string]$Mode, [string]$Prompt) {
    $script:KeyCapture = $Mode
    $ui.TxtMacroState.Text = "$Prompt  (Esc cancels)"
    $window.Focus() | Out-Null
}

$window.Add_PreviewKeyDown({
    param($s, $e)
    if (-not $script:KeyCapture) { return }
    $e.Handled = $true
    $key = if ("$($e.Key)" -eq 'System') { $e.SystemKey } else { $e.Key }
    $mode = $script:KeyCapture
    $script:KeyCapture = $null
    $ui.TxtMacroState.Text = ''
    $vk = [System.Windows.Input.KeyInterop]::VirtualKeyFromKey($key)
    if ($script:Draft) { $ui.TxtMacroBound.Text = Get-KeyName $script:Draft.HotkeyVk }
    if ("$key" -eq 'Escape' -or $vk -le 0 -or -not $script:Draft) { return }
    switch ($mode) {
        'Bind' {
            if ("$key" -eq 'Back') { $script:Draft.HotkeyVk = 0 }
            elseif ($vk -eq $StopRecordVk) { [System.Windows.MessageBox]::Show('F8 is reserved for stopping a recording. Pick another key.', $AppName) | Out-Null; return }
            else {
                $script:Draft.HotkeyVk = $vk
                if (($vk -ge 0x30 -and $vk -le 0x5A) -or $vk -eq 0x20) {
                    Write-Log "Note: while macro hotkeys are on, '$(Get-KeyName $vk)' is used only to start/stop this macro and won't type in other apps."
                }
            }
            $ui.TxtMacroBound.Text = Get-KeyName $script:Draft.HotkeyVk
            Set-DraftChanged
        }
        'Press' { Add-MacroSteps @((New-Step 'KeyDown' -Key $vk), (New-Step 'KeyUp' -Key $vk)) }
        'Hold' { Add-MacroSteps @(New-Step 'KeyDown' -Key $vk) }
        'Release' { Add-MacroSteps @(New-Step 'KeyUp' -Key $vk) }
    }
})

# ---------- Insert >> menu ----------
$InsertMenu = New-Object System.Windows.Controls.ContextMenu
function Add-InsertItem($Parent, [string]$Header, $Tag) {
    $item = New-Object System.Windows.Controls.MenuItem
    $item.Header = $Header
    if ($null -ne $Tag) {
        $item.Tag = $Tag
        $item.Add_Click({ param($s, $e); Invoke-InsertItem $s.Tag })
    }
    [void]$Parent.Items.Add($item)
    $item
}
function Invoke-InsertItem($Tag) {
    switch ($Tag.Kind) {
        'Key' { Start-KeyCapture $Tag.Mode $Tag.Prompt }
        'Delay' {
            $ms = ConvertFrom-DelayText $ui.TxtDelay.Text
            Add-MacroSteps @(New-Step 'Delay' $(if ($null -ne $ms) { $ms } else { 50 }))
        }
        'Click' { Add-MacroSteps @((New-Step 'MouseDown' -Button $Tag.Button), (New-Step 'MouseUp' -Button $Tag.Button)) }
        'MouseHold' { Add-MacroSteps @(New-Step 'MouseDown' -Button $Tag.Button) }
        'MouseRelease' { Add-MacroSteps @(New-Step 'MouseUp' -Button $Tag.Button) }
        'Wheel' { Add-MacroSteps @(New-Step 'Wheel' -Delta $Tag.Delta) }
    }
}
[void](Add-InsertItem $InsertMenu 'Key press (hold + release)...' @{ Kind = 'Key'; Mode = 'Press'; Prompt = 'Press the key to insert.' })
[void](Add-InsertItem $InsertMenu 'Key hold...' @{ Kind = 'Key'; Mode = 'Hold'; Prompt = 'Press the key to hold.' })
[void](Add-InsertItem $InsertMenu 'Key release...' @{ Kind = 'Key'; Mode = 'Release'; Prompt = 'Press the key to release.' })
[void]$InsertMenu.Items.Add((New-Object System.Windows.Controls.Separator))
[void](Add-InsertItem $InsertMenu 'Delay (length from the Delay box)' @{ Kind = 'Delay' })
[void]$InsertMenu.Items.Add((New-Object System.Windows.Controls.Separator))
foreach ($group in @(@('Mouse click', 'Click'), @('Mouse hold', 'MouseHold'), @('Mouse release', 'MouseRelease'))) {
    $sub = Add-InsertItem $InsertMenu $group[0] $null
    foreach ($b in $MacroButtons) { [void](Add-InsertItem $sub $MacroButtonNames[$b] @{ Kind = $group[1]; Button = $b }) }
}
[void](Add-InsertItem $InsertMenu 'Scroll up' @{ Kind = 'Wheel'; Delta = 120 })
[void](Add-InsertItem $InsertMenu 'Scroll down' @{ Kind = 'Wheel'; Delta = -120 })

# ---------- recording / playback state ----------
function Update-MacroState {
    $engine = [Peak.MacroEngine]
    $done = $engine::TakeRecording()
    if ($null -ne $done) { Complete-MacroRecording $done }
    $recording = $engine::IsRecording
    $busy = $recording -or $script:MacroCountdown -gt 0
    $ui.BtnMacroStartRec.IsEnabled = -not $busy -and -not $engine::IsPlaying
    $ui.BtnMacroStopRec.IsEnabled = $busy
    $ui.LstMacros.IsEnabled = -not $busy
    if ($script:MacroCountdown -gt 0 -or $script:KeyCapture) { return }
    $ui.TxtMacroState.Text = if ($recording) { "Recording... $($engine::RecordedCount) steps so far. Press F8 to stop." }
    elseif ($engine::IsPlaying) { "Playing '$($engine::PlayingName)'. Press its hotkey again or click Stop to end it." }
    elseif ($ui.ChkMacrosEnabled.IsChecked) { 'Stopped. Hotkeys on: press a macro''s key in any app or game to start or stop it.' }
    else { 'Stopped. Turn hotkeys on to play saved macros with their keys.' }
}

function Complete-MacroRecording($Recorded) {
    $d = $script:RecordDraft
    if (-not $d -or $d -ne $script:Draft) { Write-Log 'The recording finished after the macro was closed, so it was not added.' 'WARN'; return }
    $new = foreach ($r in $Recorded) {
        if ($script:RecordDelays -and $r.T -gt 0) { New-Step 'Delay' $r.T }
        New-Step $r.Type 0 $r.Key $r.Button $r.X $r.Y $r.Delta $r.Pos
    }
    if (-not $new) { Write-Log 'Nothing was recorded.' 'WARN'; return }
    Add-MacroSteps @($new) $script:RecordInsertAt
    Write-Log "Recorded $(@($new).Count) steps into '$($d.Name)'. Click Save to keep them."
}

# 3 second countdown so the player can switch to the game before recording or playback starts.
$MacroTimer = New-Object System.Windows.Threading.DispatcherTimer
$MacroTimer.Interval = [TimeSpan]::FromSeconds(1)
$MacroCountdown = 0
$MacroTimer.Add_Tick({
    $script:MacroCountdown--
    if ($script:MacroCountdown -gt 0) { $ui.TxtMacroState.Text = "$($script:MacroCountdownLabel) in $($script:MacroCountdown)... switch to your game or app now."; return }
    $MacroTimer.Stop()
    & $script:MacroCountdownAction
})
function Start-MacroCountdown([string]$Label, [scriptblock]$Action) {
    $script:MacroCountdownLabel = $Label
    $script:MacroCountdownAction = $Action
    $script:MacroCountdown = 3
    $ui.TxtMacroState.Text = "$Label in 3... switch to your game or app now."
    $MacroTimer.Start()
}

# ---------- load saved macros and fill the controls ----------
$Macros = New-Object System.Collections.ArrayList
if (Test-Path $MacroFile) {
    try { foreach ($m in Read-MacroFile $MacroFile) { [void]$Macros.Add($m) } }
    catch { Write-Log "Could not read saved macros: $($_.Exception.Message)" 'WARN' }
}
foreach ($k in $MacroSpeeds.Keys) { [void]$ui.CmbMacroSpeed.Items.Add($k) }
$Draft = $null; $DraftIndex = -1; $DraftDirty = $false; $KeyCapture = $null
Update-MacroList
Open-Draft

# ---------- events ----------
$ui.LstMacros.Add_SelectionChanged({
    if ($script:SuppressMacroList) { return }
    $target = $ui.LstMacros.SelectedIndex
    if ($script:DraftDirty) { Confirm-DraftSaved; Update-MacroList $target }
    Open-Draft
})

$ui.ChkMacrosEnabled.Add_Click({
    if (-not (Initialize-MacroEngine)) { $ui.ChkMacrosEnabled.IsChecked = $false; return }
    Update-MacroBindings
    if ($ui.ChkMacrosEnabled.IsChecked) { [Peak.MacroEngine]::Enable(); Write-Log 'Macro hotkeys on.' }
    else { [Peak.MacroEngine]::Disable(); [Peak.MacroEngine]::StopPlayback(); Write-Log 'Macro hotkeys off.' }
})

$ui.BtnMacroNew.Add_Click({
    Confirm-DraftSaved
    [void]$Macros.Add((New-MacroObject (Get-UniqueMacroName 'New macro')))
    Save-Macros
    Update-MacroList ($Macros.Count - 1)
    Open-Draft
    $ui.TxtMacroName.Focus() | Out-Null
    $ui.TxtMacroName.SelectAll()
})

$ui.BtnMacroDelete.Add_Click({
    $i = $script:DraftIndex
    if ($i -lt 0) { return }
    $ok = [System.Windows.MessageBox]::Show("Delete the macro '$($Macros[$i].Name)'?", $AppName, 'YesNo', 'Warning')
    if ($ok -ne 'Yes') { return }
    $name = $Macros[$i].Name
    $Macros.RemoveAt($i)
    Save-Macros; Update-MacroBindings
    Update-MacroList ([math]::Min($i, $Macros.Count - 1))
    Open-Draft
    Write-Log "Deleted macro '$name'."
})

$ui.BtnMacroSave.Add_Click({ Save-Draft })
$ui.BtnMacroCancel.Add_Click({ Open-Draft; Write-Log 'Changes discarded.' })

$ui.TxtMacroName.Add_TextChanged({
    if ($script:LoadingMacro -or -not $script:Draft) { return }
    $script:Draft.Name = $ui.TxtMacroName.Text
    Set-DirtyKeepCaret
})

$ui.BtnMacroStartRec.Add_Click({
    if (-not $script:Draft -or -not (Initialize-MacroEngine)) { return }
    if ([Peak.MacroEngine]::IsPlaying -or [Peak.MacroEngine]::IsRecording -or $script:MacroCountdown -gt 0) { return }
    $script:RecordDraft = $script:Draft
    $sel = Get-SelectedStepIndex
    $script:RecordInsertAt = if ($sel -ge 0) { $sel + 1 } else { @($script:Draft.Events).Count }
    $script:RecordDelays = [bool]$ui.ChkRecDelays.IsChecked
    $script:RecordOptions = @([bool]$ui.ChkRecMoves.IsChecked, [bool]$ui.ChkRecClicks.IsChecked, [bool]($ui.ChkRecClicks.IsChecked -and $ui.ChkRecClickPos.IsChecked))
    Start-MacroCountdown 'Recording starts' { [Peak.MacroEngine]::StartRecording($script:RecordOptions[0], $script:RecordOptions[1], $script:RecordOptions[2]) }
})
$ui.BtnMacroStopRec.Add_Click({
    if ($script:MacroCountdown -gt 0) { $MacroTimer.Stop(); $script:MacroCountdown = 0; return }
    if ($script:MacroEngineReady) { [Peak.MacroEngine]::EndRecording($true) }
})

$ui.BtnMacroInsert.Add_Click({
    $InsertMenu.PlacementTarget = $ui.BtnMacroInsert
    $InsertMenu.Placement = 'Right'
    $InsertMenu.IsOpen = $true
})
$ui.BtnMacroDeleteStep.Add_Click({
    $i = Get-SelectedStepIndex
    if ($i -lt 0) { return }
    $list = [System.Collections.ArrayList]@($script:Draft.Events)
    $list.RemoveAt($i)
    $script:Draft.Events = $list.ToArray()
    Set-DraftChanged ([math]::Min($i, $list.Count - 1))
})
foreach ($dir in @(@('BtnMacroUp', -1), @('BtnMacroDown', 1))) {
    $ui[$dir[0]].Tag = $dir[1]
    $ui[$dir[0]].Add_Click({
        param($s, $e)
        $i = Get-SelectedStepIndex
        $j = $i + $s.Tag
        if ($i -lt 0 -or $j -lt 0 -or $j -ge @($script:Draft.Events).Count) { return }
        $steps = @($script:Draft.Events)
        $steps[$i], $steps[$j] = $steps[$j], $steps[$i]
        $script:Draft.Events = $steps
        Set-DraftChanged $j
    })
}
$ui.LstMacroSteps.Add_SelectionChanged({ if (-not $script:LoadingMacro) { Sync-DelayBox } })
$ui.TxtDelay.Add_TextChanged({ if (-not $script:LoadingMacro) { Set-DelayFromBox } })
$ui.BtnDelayUp.Add_Click({ Step-DelayBox 0.01 })
$ui.BtnDelayDown.Add_Click({ Step-DelayBox -0.01 })

$ui.BtnMacroBind.Add_Click({
    if ($script:Draft) { Start-KeyCapture 'Bind' 'Press the key to bind this macro to. Backspace removes the binding.' ; $ui.TxtMacroBound.Text = '...' }
})

function Set-DraftRepeat {
    if ($script:LoadingMacro -or -not $script:Draft) { return }
    $count = 0
    [void][int]::TryParse($ui.TxtRepeatCount.Text, [ref]$count)
    $count = [math]::Min([math]::Max(2, $count), 9999)
    $value = if ($ui.RbMacroOnce.IsChecked) { 1 } elseif ($ui.RbMacroLoop.IsChecked) { 0 } else { $count }
    $ui.TxtRepeatCount.IsEnabled = [bool]$ui.RbMacroRepeat.IsChecked
    if ($script:Draft.Repeat -ne $value) { $script:Draft.Repeat = $value; Set-DirtyKeepCaret }
}
foreach ($rb in $ui.RbMacroOnce, $ui.RbMacroRepeat, $ui.RbMacroLoop) { $rb.Add_Checked({ Set-DraftRepeat }) }
$ui.TxtRepeatCount.Add_LostFocus({ $script:LoadingMacro = $true; $c = 0; [void][int]::TryParse($ui.TxtRepeatCount.Text, [ref]$c); $ui.TxtRepeatCount.Text = "$([math]::Min([math]::Max(2, $c), 9999))"; $script:LoadingMacro = $false; Set-DraftRepeat })
$ui.TxtRepeatCount.Add_TextChanged({ Set-DraftRepeat })
foreach ($dir in @(@('BtnRepeatUp', 1), @('BtnRepeatDown', -1))) {
    $ui[$dir[0]].Tag = $dir[1]
    $ui[$dir[0]].Add_Click({
        param($s, $e)
        $c = 0; [void][int]::TryParse($ui.TxtRepeatCount.Text, [ref]$c)
        $ui.RbMacroRepeat.IsChecked = $true
        $ui.TxtRepeatCount.Text = "$([math]::Min([math]::Max(2, $c + $s.Tag), 9999))"
    })
}
$ui.CmbMacroSpeed.Add_SelectionChanged({
    if ($script:LoadingMacro -or -not $script:Draft -or -not $ui.CmbMacroSpeed.SelectedItem) { return }
    $script:Draft.Speed = $MacroSpeeds[[string]$ui.CmbMacroSpeed.SelectedItem]
    Set-DirtyKeepCaret
})

$ui.BtnMacroPlay.Add_Click({
    $d = $script:Draft
    if (-not $d -or -not @($d.Events).Count -or -not (Initialize-MacroEngine)) { return }
    if ([Peak.MacroEngine]::IsPlaying -or [Peak.MacroEngine]::IsRecording -or $script:MacroCountdown -gt 0) { return }
    $script:PendingPlay = ConvertTo-EngineMacro $d   # plays the current edits, saved or not
    Start-MacroCountdown "Playing '$($d.Name)'" { [Peak.MacroEngine]::Play($script:PendingPlay) }
})
$ui.BtnMacroStopPlay.Add_Click({
    if ($script:MacroCountdown -gt 0) { $MacroTimer.Stop(); $script:MacroCountdown = 0 }
    if ($script:MacroEngineReady) { [Peak.MacroEngine]::StopPlayback() }
})

# ---------- import / export ----------
function Export-Macros([object[]]$List, [string]$FileName) {
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = 'Peak macros (*.json)|*.json'
    $dlg.FileName = ($FileName -replace '[\\/:*?"<>|]', '_') + '.json'
    if (-not $dlg.ShowDialog()) { return }
    ConvertTo-Json -InputObject @{ PeakMacros = 2; Macros = @($List) } -Depth 6 | Set-Content -Path $dlg.FileName -Encoding UTF8
    Write-Log "Exported $($List.Count) macro(s) to $($dlg.FileName)"
}
$ui.BtnMacroExport.Add_Click({
    if ($script:DraftIndex -lt 0) { [System.Windows.MessageBox]::Show('Select a macro to export, or use Export All.', $AppName) | Out-Null; return }
    Confirm-DraftSaved
    Export-Macros @($Macros[$script:DraftIndex]) $Macros[$script:DraftIndex].Name
})
$ui.BtnMacroExportAll.Add_Click({
    if (-not $Macros.Count) { [System.Windows.MessageBox]::Show('There are no macros to export yet.', $AppName) | Out-Null; return }
    Confirm-DraftSaved
    Export-Macros @($Macros) 'peak-macros'
})
$ui.BtnMacroImport.Add_Click({
    Confirm-DraftSaved
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'Peak macros (*.json)|*.json|All files (*.*)|*.*'
    $dlg.Multiselect = $true
    if (-not $dlg.ShowDialog()) { return }
    $added = @()
    foreach ($file in $dlg.FileNames) {
        try {
            foreach ($m in Read-MacroFile $file) {
                if (-not @($m.Events).Count) { continue }
                $m.Name = Get-UniqueMacroName $m.Name
                # Never let an imported macro silently take over a key that is already bound.
                if ($m.HotkeyVk -and @($Macros | Where-Object { $_.HotkeyVk -eq $m.HotkeyVk })) { $m.HotkeyVk = 0 }
                [void]$Macros.Add($m)
                $added += $m
            }
        } catch { Write-Log "Could not import ${file}: $($_.Exception.Message)" 'ERROR' }
    }
    if (-not $added) { Write-Log 'No macros were found in the selected file(s).' 'WARN'; return }
    Save-Macros; Update-MacroBindings
    Update-MacroList ($Macros.Count - 1)
    Open-Draft
    Write-Log "Imported $($added.Count) macro(s): $(($added | ForEach-Object Name) -join ', ')"
})
#endregion

#region Display, peripherals and background apps -------------------------------------------
# Small native helper, compiled the first time the Display or Peripherals tab is opened.
$NativeSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace Peak
{
    public class DisplayMode { public int Width { get; set; } public int Height { get; set; } public int Hz { get; set; } }

    public class DisplayInfo
    {
        public string Device { get; set; }
        public string Adapter { get; set; }
        public string MonitorName { get; set; }
        public string MonitorId { get; set; }
        public bool Primary { get; set; }
        public int Width { get; set; }
        public int Height { get; set; }
        public int Hz { get; set; }
        public int Bits { get; set; }
        public List<DisplayMode> Modes { get; set; }
    }

    public static class Native
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct DISPLAY_DEVICE
        {
            public int cb;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
            public int StateFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct DEVMODE
        {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
            public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
            public int dmFields;
            public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
            public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
            public short dmLogPixels;
            public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
            public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplayDevices(string device, uint index, ref DISPLAY_DEVICE dd, uint flags);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettings(string device, int mode, ref DEVMODE dm);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int ChangeDisplaySettingsEx(string device, ref DEVMODE dm, IntPtr hwnd, uint flags, IntPtr param);
        [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW")] static extern bool SpiGetInt(uint action, uint param, ref int value, uint ini);
        [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW")] static extern bool SpiInts(uint action, uint param, int[] value, uint ini);
        [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW")] static extern bool SpiSet(uint action, uint param, IntPtr value, uint ini);
        [DllImport("user32.dll")] static extern uint GetDoubleClickTime();
        [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);

        const int CURRENT = -1;
        const uint SAVE = 0x01 | 0x02;   // write to the user profile and tell running apps

        static DEVMODE NewDevMode() { var dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE)); return dm; }

        public static List<DisplayInfo> GetDisplays()
        {
            var list = new List<DisplayInfo>();
            for (uint i = 0; i < 64; i++)
            {
                var dd = new DISPLAY_DEVICE(); dd.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
                if (!EnumDisplayDevices(null, i, ref dd, 0)) break;
                if ((dd.StateFlags & 1) == 0) continue;   // not part of the desktop
                var info = new DisplayInfo { Device = dd.DeviceName, Adapter = dd.DeviceString, Primary = (dd.StateFlags & 4) != 0, Modes = new List<DisplayMode>() };
                var mon = new DISPLAY_DEVICE(); mon.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
                if (EnumDisplayDevices(dd.DeviceName, 0, ref mon, 0)) { info.MonitorName = mon.DeviceString; info.MonitorId = mon.DeviceID; }
                var cur = NewDevMode();
                if (EnumDisplaySettings(dd.DeviceName, CURRENT, ref cur)) { info.Width = cur.dmPelsWidth; info.Height = cur.dmPelsHeight; info.Hz = cur.dmDisplayFrequency; info.Bits = cur.dmBitsPerPel; }
                var seen = new HashSet<string>();
                for (int m = 0; m < 4096; m++)
                {
                    var mode = NewDevMode();
                    if (!EnumDisplaySettings(dd.DeviceName, m, ref mode)) break;
                    if (info.Bits > 0 && mode.dmBitsPerPel != info.Bits) continue;
                    if (seen.Add(mode.dmPelsWidth + "x" + mode.dmPelsHeight + "@" + mode.dmDisplayFrequency))
                        info.Modes.Add(new DisplayMode { Width = mode.dmPelsWidth, Height = mode.dmPelsHeight, Hz = mode.dmDisplayFrequency });
                }
                list.Add(info);
            }
            return list;
        }

        // 0 = done, 1 = restart needed, negative = refused by the driver. test: only check, change nothing.
        public static int SetMode(string device, int width, int height, int hz, bool test)
        {
            var dm = NewDevMode();
            if (!EnumDisplaySettings(device, CURRENT, ref dm)) return -100;
            dm.dmPelsWidth = width; dm.dmPelsHeight = height; dm.dmDisplayFrequency = hz;
            dm.dmFields = 0x80000 | 0x100000 | 0x400000;   // width, height, frequency
            return ChangeDisplaySettingsEx(device, ref dm, IntPtr.Zero, test ? 2u : 1u, IntPtr.Zero);
        }

        // Mouse and keyboard settings: the same calls Windows Settings uses, applied instantly and saved.
        public static int MouseSpeed { get { int v = 10; SpiGetInt(0x0070, 0, ref v, 0); return v; } set { SpiSet(0x0071, 0, (IntPtr)value, SAVE); } }
        public static bool MouseAcceleration
        {
            get { var v = new int[3]; SpiInts(0x0003, 0, v, 0); return v[2] != 0; }
            set { SpiInts(0x0004, 0, value ? new[] { 6, 10, 1 } : new[] { 0, 0, 0 }, SAVE); }
        }
        public static bool SwapButtons { get { return GetSystemMetrics(23) != 0; } set { SpiSet(0x0021, value ? 1u : 0u, IntPtr.Zero, SAVE); } }
        public static int ScrollLines { get { int v = 3; SpiGetInt(0x0068, 0, ref v, 0); return v; } set { SpiSet(0x0069, (uint)value, IntPtr.Zero, SAVE); } }
        public static int DoubleClickTime { get { return (int)GetDoubleClickTime(); } set { SpiSet(0x0020, (uint)value, IntPtr.Zero, SAVE); } }
        public static int KeyboardDelay { get { int v = 1; SpiGetInt(0x0016, 0, ref v, 0); return v; } set { SpiSet(0x0017, (uint)value, IntPtr.Zero, SAVE); } }
        public static int KeyboardSpeed { get { int v = 31; SpiGetInt(0x000A, 0, ref v, 0); return v; } set { SpiSet(0x000B, (uint)value, IntPtr.Zero, SAVE); } }
    }
}
'@

$NativeReady = $false
function Initialize-Native {
    if ($script:NativeReady) { return $true }
    try {
        if (-not ('Peak.Native' -as [type])) { Add-Type -TypeDefinition $NativeSource -ErrorAction Stop }
        $script:NativeReady = $true
    } catch { Write-Log "Display/peripheral helper failed to load: $($_.Exception.Message)" 'ERROR' }
    $script:NativeReady
}

# ---------- Display ----------
function Get-MonitorNames {
    $names = @{}
    foreach ($m in Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction SilentlyContinue) {
        $code = ($m.InstanceName -split '\\')[1]
        $name = -join ($m.UserFriendlyName | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ })
        if ($code -and $name) { $names[$code] = $name }
    }
    $names
}

function Show-Displays {
    if (-not (Initialize-Native)) { return }
    $script:DisplaysLoaded = $true
    $names = Get-MonitorNames
    $ui.DisplayPanel.Children.Clear()
    $n = 0
    foreach ($d in [Peak.Native]::GetDisplays()) {
        $n++
        $code = if ($d.MonitorId) { ($d.MonitorId -split '\\')[1] }
        $title = if ($code -and $names[$code]) { $names[$code] } elseif ($d.MonitorName) { $d.MonitorName } else { "Display $n" }
        if ($d.Primary) { $title += '  (main display)' }
        $card = New-Card $title 420
        [void]$card.Child.Children.Add((New-TextLine "$($d.Device -replace '^\\\\\.\\', '') on $($d.Adapter)" -Muted))
        [void]$card.Child.Children.Add((New-TextLine "Now: $($d.Width) x $($d.Height) at $($d.Hz) Hz" -Color '#5FD38D'))

        $grid = New-Object System.Windows.Controls.Grid
        $grid.Margin = [System.Windows.Thickness]::new(0, 6, 0, 0)
        foreach ($w in 1, 1) { $c = New-Object System.Windows.Controls.ColumnDefinition; $c.Width = New-Object System.Windows.GridLength($w, 'Star'); $grid.ColumnDefinitions.Add($c) }
        $resBox = New-Object System.Windows.Controls.ComboBox; $resBox.Padding = [System.Windows.Thickness]::new(6, 4, 6, 4); $resBox.Margin = [System.Windows.Thickness]::new(0, 0, 6, 0)
        $hzBox = New-Object System.Windows.Controls.ComboBox; $hzBox.Padding = [System.Windows.Thickness]::new(6, 4, 6, 4)
        [System.Windows.Controls.Grid]::SetColumn($hzBox, 1)
        [void]$grid.Children.Add($resBox); [void]$grid.Children.Add($hzBox)
        [void]$card.Child.Children.Add((New-TextLine 'Resolution / refresh rate' -Muted))
        [void]$card.Child.Children.Add($grid)

        $resolutions = @($d.Modes | Sort-Object { $_.Width * $_.Height }, Width -Descending | ForEach-Object { "$($_.Width) x $($_.Height)" } | Select-Object -Unique)
        foreach ($r in $resolutions) { [void]$resBox.Items.Add($r) }
        $state = @{ Display = $d; Res = $resBox; Hz = $hzBox }
        $resBox.Tag = $state
        $resBox.Add_SelectionChanged({
            param($s, $e)
            $st = $s.Tag
            $w, $h = ([string]$s.SelectedItem -split ' x ') | ForEach-Object { [int]$_ }
            $rates = @($st.Display.Modes | Where-Object { $_.Width -eq $w -and $_.Height -eq $h } | ForEach-Object Hz | Sort-Object -Descending -Unique)
            $st.Hz.Items.Clear()
            foreach ($r in $rates) { [void]$st.Hz.Items.Add("$r Hz") }
            $keep = "$($st.Display.Hz) Hz"
            $st.Hz.SelectedItem = if ($st.Hz.Items.Contains($keep)) { $keep } else { $st.Hz.Items[0] }
        })
        $resBox.SelectedItem = "$($d.Width) x $($d.Height)"

        $row = New-Object System.Windows.Controls.WrapPanel
        $row.Margin = [System.Windows.Thickness]::new(-4, 8, 0, 0)
        $apply = New-Object System.Windows.Controls.Button; $apply.Content = 'Apply'; $apply.Style = $window.FindResource('AccentButton'); $apply.Tag = $state
        $apply.Add_Click({
            param($s, $e)
            $st = $s.Tag
            if (-not $st.Res.SelectedItem -or -not $st.Hz.SelectedItem) { return }
            $w, $h = ([string]$st.Res.SelectedItem -split ' x ') | ForEach-Object { [int]$_ }
            Set-DisplayMode $st.Display $w $h ([int]([string]$st.Hz.SelectedItem -replace '\D'))
        })
        $max = New-Object System.Windows.Controls.Button; $max.Content = 'Max Refresh Rate'; $max.Tag = $state
        $max.ToolTip = 'Highest refresh rate this monitor supports at its current resolution'
        $max.Add_Click({
            param($s, $e)
            $d = $s.Tag.Display
            $top = ($d.Modes | Where-Object { $_.Width -eq $d.Width -and $_.Height -eq $d.Height } | Measure-Object Hz -Maximum).Maximum
            if ($top -le $d.Hz) { Write-Log "$($d.Device): already at its highest refresh rate ($($d.Hz) Hz)."; return }
            Set-DisplayMode $d $d.Width $d.Height ([int]$top)
        })
        [void]$row.Children.Add($apply); [void]$row.Children.Add($max)
        [void]$card.Child.Children.Add($row)

        $top = ($d.Modes | Where-Object { $_.Width -eq $d.Width -and $_.Height -eq $d.Height } | Measure-Object Hz -Maximum).Maximum
        if ($top -gt $d.Hz) { [void]$card.Child.Children.Add((New-TextLine "This monitor supports up to $top Hz at this resolution - you're using $($d.Hz) Hz." -Color '#FFB454')) }
        [void]$ui.DisplayPanel.Children.Add($card)
    }
}

$DisplayTimer = New-Object System.Windows.Threading.DispatcherTimer
$DisplayTimer.Interval = [TimeSpan]::FromSeconds(1)
$DisplayTimer.Add_Tick({
    $script:DisplayCountdown--
    if ($script:DisplayCountdown -gt 0) { $ui.TxtDisplayConfirm.Text = "Keep these display settings? Switching back in $($script:DisplayCountdown) seconds."; return }
    Complete-DisplayChange $false
})

function Set-DisplayMode($D, [int]$W, [int]$H, [int]$Hz) {
    if ($script:DisplayUndo) { return }   # waiting for Keep / Revert on the previous change
    if ($W -eq $D.Width -and $H -eq $D.Height -and $Hz -eq $D.Hz) { Write-Log 'The display is already using that mode.'; return }
    $test = [Peak.Native]::SetMode($D.Device, $W, $H, $Hz, $true)
    if ($test -ne 0) { Write-Log "$W x $H at $Hz Hz isn't accepted by this display (code $test)." 'WARN'; return }
    $script:DisplayUndo = @{ Device = $D.Device; W = $D.Width; H = $D.Height; Hz = $D.Hz }
    $r = [Peak.Native]::SetMode($D.Device, $W, $H, $Hz, $false)
    if ($r -lt 0) { $script:DisplayUndo = $null; Write-Log "Changing the display failed (code $r)." 'ERROR'; return }
    Write-Log "Display set to $W x $H at $Hz Hz."
    $script:DisplayCountdown = 15
    $ui.TxtDisplayConfirm.Text = 'Keep these display settings? Switching back in 15 seconds.'
    $ui.DisplayConfirm.Visibility = 'Visible'
    $DisplayTimer.Start()
}

function Complete-DisplayChange([bool]$Keep) {
    $DisplayTimer.Stop()
    $ui.DisplayConfirm.Visibility = 'Collapsed'
    $u = $script:DisplayUndo
    $script:DisplayUndo = $null
    if ($u -and -not $Keep) {
        [void][Peak.Native]::SetMode($u.Device, $u.W, $u.H, $u.Hz, $false)
        Write-Log "Display switched back to $($u.W) x $($u.H) at $($u.Hz) Hz."
    } elseif ($u) { Write-Log 'New display settings kept.' }
    Show-Displays
}

$ui.BtnDisplayKeep.Add_Click({ Complete-DisplayChange $true })
$ui.BtnDisplayRevert.Add_Click({ Complete-DisplayChange $false })
$ui.BtnDisplayRefresh.Add_Click({ Show-Displays })

# ---------- Peripherals ----------
$KeyDelayNames = '250 ms (shortest)', '500 ms', '750 ms', '1 second (longest)'
function Update-PeriphLabels {
    $speed = [int]$ui.SldMouseSpeed.Value
    $ui.TxtMouseSpeed.Text = "$speed / 20" + $(if ($speed -eq 10) { '  (default, 1:1)' } else { '' })
    $ui.TxtScrollLines.Text = "$([int]$ui.SldScrollLines.Value) lines"
    $ui.TxtDoubleClick.Text = "$([int]$ui.SldDoubleClick.Value) ms"
    $ui.TxtKeyDelay.Text = $KeyDelayNames[[int]$ui.SldKeyDelay.Value]
    $ui.TxtKeyRate.Text = '{0:N0} per second' -f (2.5 + [int]$ui.SldKeyRate.Value * 27.5 / 31)
}

# Sliders apply 300 ms after you stop dragging, so Windows isn't flooded with setting changes.
$PeriphPending = @{}
$PeriphTimer = New-Object System.Windows.Threading.DispatcherTimer
$PeriphTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$PeriphTimer.Add_Tick({
    $PeriphTimer.Stop()
    foreach ($k in @($PeriphPending.Keys)) {
        try { [Peak.Native]::$k = $PeriphPending[$k] } catch { Write-Log "${k}: $($_.Exception.Message)" 'ERROR' }
    }
    if ($PeriphPending.Count) { Write-Log "Updated: $(($PeriphPending.Keys | Sort-Object) -join ', ')." }
    $PeriphPending.Clear()
})
function Set-PeriphLater([string]$Name, $Value) {
    if ($script:LoadingPeriph -or -not $script:NativeReady) { return }
    $PeriphPending[$Name] = $Value
    $PeriphTimer.Stop(); $PeriphTimer.Start()
}

function Show-Peripherals {
    if (-not (Initialize-Native)) { return }
    $script:PeriphLoaded = $true
    $script:LoadingPeriph = $true
    try {
        $ui.SldMouseSpeed.Value = [Peak.Native]::MouseSpeed
        $ui.ChkMouseAccel.IsChecked = [Peak.Native]::MouseAcceleration
        $ui.ChkMouseSwap.IsChecked = [Peak.Native]::SwapButtons
        $ui.SldScrollLines.Value = [math]::Min([math]::Max(1, [Peak.Native]::ScrollLines), 20)
        $ui.SldDoubleClick.Value = [math]::Min([math]::Max(200, [Peak.Native]::DoubleClickTime), 900)
        $ui.SldKeyDelay.Value = [Peak.Native]::KeyboardDelay
        $ui.SldKeyRate.Value = [Peak.Native]::KeyboardSpeed
    } finally { $script:LoadingPeriph = $false }
    Update-PeriphLabels
    Show-InputDevices
}

function Show-InputDevices {
    $ui.DevicePanel.Children.Clear()
    $devices = @(Get-PnpDevice -PresentOnly -Class Keyboard, Mouse -ErrorAction SilentlyContinue | Where-Object Status -eq 'OK')
    if (-not $devices) { [void]$ui.DevicePanel.Children.Add((New-TextLine 'No keyboards or mice were found.' -Muted)); return }
    # HID devices have generic names; the USB/Bluetooth node above them has the product name.
    $parents = @{}
    foreach ($p in Get-PnpDeviceProperty -InstanceId @($devices.InstanceId) -KeyName DEVPKEY_Device_Parent -ErrorAction SilentlyContinue) { $parents[$p.InstanceId] = $p.Data }
    $names = @{}
    $ids = @($parents.Values | Where-Object { $_ } | Select-Object -Unique)
    if ($ids) { foreach ($p in Get-PnpDeviceProperty -InstanceId $ids -KeyName DEVPKEY_Device_BusReportedDeviceDesc -ErrorAction SilentlyContinue) { if ($p.Data) { $names[$p.InstanceId] = $p.Data } } }
    $rows = foreach ($d in $devices) {
        $product = $names[[string]$parents[$d.InstanceId]]
        $vid = if ($d.InstanceId -match 'VID[_&]([0-9A-F]{4})') { $Matches[1] } else { $null }
        [pscustomobject]@{
            Kind = if ($d.Class -eq 'Mouse') { 'Mouse' } else { 'Keyboard' }
            Name = if ($product) { $product } else { $d.FriendlyName }
            Connection = if ($d.InstanceId -match 'BTH') { 'Bluetooth' } elseif ($d.InstanceId -match '^HID\\VID|USB') { 'USB' } elseif ($d.InstanceId -match '^ACPI') { 'Built-in' } else { 'Other' }
            Vid = $vid
        }
    }
    foreach ($g in $rows | Group-Object Kind, Name, Connection | Sort-Object { $_.Group[0].Kind }, Name) {
        $r = $g.Group[0]
        $count = if ($g.Count -gt 1) { "  ($($g.Count) interfaces)" } else { '' }
        [void]$ui.DevicePanel.Children.Add((New-TextLine "$($r.Kind): $($r.Name) - $($r.Connection)$count"))
    }
}

$ui.SldMouseSpeed.Add_ValueChanged({ Update-PeriphLabels; Set-PeriphLater 'MouseSpeed' ([int]$ui.SldMouseSpeed.Value) })
$ui.SldScrollLines.Add_ValueChanged({ Update-PeriphLabels; Set-PeriphLater 'ScrollLines' ([int]$ui.SldScrollLines.Value) })
$ui.SldDoubleClick.Add_ValueChanged({ Update-PeriphLabels; Set-PeriphLater 'DoubleClickTime' ([int]$ui.SldDoubleClick.Value) })
$ui.SldKeyDelay.Add_ValueChanged({ Update-PeriphLabels; Set-PeriphLater 'KeyboardDelay' ([int]$ui.SldKeyDelay.Value) })
$ui.SldKeyRate.Add_ValueChanged({ Update-PeriphLabels; Set-PeriphLater 'KeyboardSpeed' ([int]$ui.SldKeyRate.Value) })
$ui.ChkMouseAccel.Add_Click({
    if (-not (Initialize-Native)) { return }
    [Peak.Native]::MouseAcceleration = [bool]$ui.ChkMouseAccel.IsChecked
    Write-Log ('Mouse acceleration (enhance pointer precision): {0}' -f $(if ($ui.ChkMouseAccel.IsChecked) { 'On' } else { 'Off' }))
})
$ui.ChkMouseSwap.Add_Click({
    if (-not (Initialize-Native)) { return }
    [Peak.Native]::SwapButtons = [bool]$ui.ChkMouseSwap.IsChecked
    Write-Log ('Primary mouse button: {0}' -f $(if ($ui.ChkMouseSwap.IsChecked) { 'Right' } else { 'Left' }))
})
$ui.BtnMouseDefaults.Add_Click({
    if (-not (Initialize-Native)) { return }
    [Peak.Native]::MouseSpeed = 10; [Peak.Native]::MouseAcceleration = $true; [Peak.Native]::SwapButtons = $false
    [Peak.Native]::ScrollLines = 3; [Peak.Native]::DoubleClickTime = 500
    Show-Peripherals; Write-Log 'Mouse settings reset to Windows defaults.'
})
$ui.BtnKeyboardDefaults.Add_Click({
    if (-not (Initialize-Native)) { return }
    [Peak.Native]::KeyboardDelay = 1; [Peak.Native]::KeyboardSpeed = 31
    Show-Peripherals; Write-Log 'Keyboard settings reset to Windows defaults.'
})
$ui.BtnRefreshDevices.Add_Click({ Show-InputDevices })

# ---------- Background apps ----------
# 'process|label|end?|note' - end? = 1 means safe and pre-selected for ending.
$BgKnown = @{}
@(
    'msedge|Microsoft Edge (background)|1|Edge keeps running after you close it (Startup boost).'
    'MicrosoftEdgeUpdate|Edge updater|1|Checks for Edge updates.'
    'GoogleUpdate|Google updater|1|Checks for Chrome/Google updates.'
    'GoogleCrashHandler|Google crash reporter|1|Sends Google crash reports.'
    'GoogleCrashHandler64|Google crash reporter|1|Sends Google crash reports.'
    'OneDrive|OneDrive|1|Cloud sync pauses until you open OneDrive again.'
    'PhoneExperienceHost|Phone Link|1|Phone notifications on the PC stop until you open it.'
    'YourPhone|Phone Link|1|Phone notifications on the PC stop until you open it.'
    'Widgets|Windows Widgets|1|Reopens when you open the Widgets board.'
    'WidgetService|Windows Widgets|1|Reopens when you open the Widgets board.'
    'MicrosoftStartFeedProvider|Windows Widgets|1|Reopens when you open the Widgets board.'
    'ms-teams|Microsoft Teams|1|Teams notifications stop until you open it.'
    'MSTeams|Microsoft Teams|1|Teams notifications stop until you open it.'
    'Teams|Microsoft Teams|1|Teams notifications stop until you open it.'
    'Skype|Skype|1|Skype notifications stop until you open it.'
    'Copilot|Microsoft Copilot|1|Reopens when you use Copilot.'
    'Cortana|Cortana|1|Reopens when you use Cortana.'
    'GameBar|Xbox Game Bar|1|Reopens when you press Win+G.'
    'GameBarFTServer|Xbox Game Bar helper|1|Reopens when you press Win+G.'
    'AdobeARM|Adobe updater|1|Checks for Adobe Reader updates.'
    'AcrobatNotificationClient|Adobe Acrobat notifications|1|Adobe pop-ups.'
    'AdobeCollabSync|Adobe Acrobat sync|1|Adobe document sync.'
    'CCXProcess|Adobe Creative Cloud helper|1|Starts again with Creative Cloud apps.'
    'CoreSync|Adobe file sync|1|Starts again with Creative Cloud.'
    'Adobe Desktop Service|Adobe Creative Cloud service|1|Starts again with Creative Cloud apps.'
    'AdobeIPCBroker|Adobe helper|1|Starts again with Adobe apps.'
    'jusched|Java updater|1|Checks for Java updates.'
    'CCleaner64|CCleaner monitoring|1|Background monitoring and pop-ups.'
    'iTunesHelper|iTunes helper|1|Starts iTunes when an iPhone is plugged in.'
    'SpotifyWebHelper|Spotify web helper|1|Not needed for Spotify to play.'
    'lghub_updater|Logitech G HUB updater|1|Checks for G HUB updates.'
    'Steam|Steam|0|Needed to play Steam games (Rust, Siege on Steam).'
    'steamwebhelper|Steam|0|Part of Steam.'
    'EpicGamesLauncher|Epic Games Launcher|0|Needed to play Epic games (Fortnite).'
    'EpicWebHelper|Epic Games Launcher|0|Needed to play Epic games (Fortnite).'
    'EpicOnlineServicesUserHelper|Epic Games Launcher|0|Needed to play Epic games (Fortnite).'
    'EOSOverlayRenderer-Win64-Shipping|Epic Games Launcher|0|Needed to play Epic games (Fortnite).'
    'MedalEncoder|Medal.tv|0|Clip recording stops.'
    'StreamDeck|Elgato Stream Deck|0|Stream Deck buttons stop working.'
    'wallpaper32|Wallpaper Engine|0|Animated wallpaper stops (it already pauses itself during games).'
    'wallpaper64|Wallpaper Engine|0|Animated wallpaper stops (it already pauses itself during games).'
    'NVIDIA Share|NVIDIA overlay|0|ShadowPlay recording and the Alt+Z overlay stop.'
    'nvsphelper64|NVIDIA overlay|0|ShadowPlay recording and the Alt+Z overlay stop.'
    'upc|Ubisoft Connect|0|Needed to play Ubisoft games (Siege).'
    'UbisoftConnect|Ubisoft Connect|0|Needed to play Ubisoft games (Siege).'
    'EADesktop|EA app|0|Needed to play EA games.'
    'Battle.net|Battle.net|0|Needed to play Blizzard games.'
    'RiotClientServices|Riot Client|0|Needed to play Riot games.'
    'GalaxyClient|GOG Galaxy|0|Needed to play GOG games through Galaxy.'
    'Discord|Discord|0|Voice chat and messages stop.'
    'Spotify|Spotify|0|Music stops.'
    'Dropbox|Dropbox|0|Cloud sync pauses.'
    'GoogleDriveFS|Google Drive|0|Cloud sync pauses.'
    'Overwolf|Overwolf|0|Game add-ons stop.'
    'Medal|Medal.tv|0|Clip recording stops.'
    'iCUE|Corsair iCUE|0|RGB lighting, DPI profiles and macros from iCUE stop.'
    'lghub|Logitech G HUB|0|Lighting, DPI profiles and macros from G HUB stop.'
    'lghub_agent|Logitech G HUB|0|Lighting, DPI profiles and macros from G HUB stop.'
    'RazerAppEngine|Razer Synapse|0|Lighting, DPI profiles and macros from Synapse stop.'
    'SteelSeriesGG|SteelSeries GG|0|Lighting and device profiles stop.'
    'SteelSeriesEngine|SteelSeries Engine|0|Lighting and device profiles stop.'
    'ArmouryCrate|ASUS Armoury Crate|0|Lighting and fan profiles stop.'
    'ArmourySocketServer|ASUS Armoury Crate|0|Lighting and fan profiles stop.'
    'ArmouryCrate.UserSessionHelper|ASUS Armoury Crate|0|Lighting and fan profiles stop.'
    'ArmourySwAgent|ASUS Armoury Crate|0|Lighting and fan profiles stop.'
    'SignalRgb|SignalRGB|0|RGB lighting stops.'
    'RadeonSoftware|AMD Software (Adrenalin)|0|Overlay and hotkeys stop; the graphics driver keeps working.'
    'MSIAfterburner|MSI Afterburner|0|GPU overclock/fan curve and overlay stop.'
    'RTSS|RivaTuner Statistics Server|0|FPS limiter and overlay stop.'
) | ForEach-Object {
    $p = $_ -split '\|'
    $BgKnown[$p[0]] = @{ Label = $p[1]; End = $p[2] -eq '1'; Note = $p[3] }
}
# Never listed: Windows, security, anti-cheat and hardware-driver helpers.
$BgNever = '^(explorer|dwm|csrss|winlogon|lsass|services|smss|wininit|fontdrvhost|sihost|ctfmon|RuntimeBroker|ShellExperienceHost|' +
    'StartMenuExperienceHost|SearchHost|SearchApp|TextInputHost|SecurityHealth.*|audiodg|conhost|dllhost|taskhostw|ApplicationFrameHost|' +
    'SystemSettings|LockApp|smartscreen|WmiPrvSE|svchost|msedgewebview2|powershell|pwsh|WindowsTerminal|OpenConsole|cmd|' +
    'vgc|vgtray|EasyAntiCheat.*|BEService.*|BEDaisy|FACEIT.*|faceit.*|EAAntiCheat.*|PnkBstr.*|mbam.*|MBAM.*|MsMpEng|NisSrv|' +
    'avp|avast.*|AvastUI|avg.*|ekrn|egui|bdagent|vsserv|NortonSecurity|' +
    'NVDisplay\.Container|nvcontainer|atiesrxx|atieclxx|amdfendr.*|AMDRS.*|amdow|RtkAud.*|RtkNGUI.*|Realtek.*|Nahimic.*|A3DUtility|Waves.*|' +
    'igfx.*|IntelCpHDCPSvc|jhi_service|LMS|esif_.*|SynTP.*|ETDCtrl|Wacom.*|WTablet.*)$'

function Get-BackgroundApps {
    $session = (Get-Process -Id $PID).SessionId
    $all = @(Get-Process | Where-Object { $_.SessionId -eq $session })
    $byId = @{}
    foreach ($p in $all) { $byId[$p.Id] = $p }
    $windowed = @{}
    foreach ($p in $all) { if ($p.MainWindowHandle -ne [IntPtr]::Zero) { $windowed[$p.Name] = $true } }
    $parentOf = @{}
    foreach ($w in Get-CimInstance Win32_Process -Filter "SessionId = $session" -Property ProcessId, ParentProcessId -ErrorAction SilentlyContinue) { $parentOf[[int]$w.ProcessId] = [int]$w.ParentProcessId }
    $entries = [ordered]@{}
    foreach ($g in $all | Where-Object { $_.Id -ne $PID } | Group-Object Name) {
        $name = $g.Name
        if ($name -match $BgNever -or $windowed[$name]) { continue }   # system/protected, or an app you have open
        # Helpers of an app you have open (e.g. a code editor's background workers) are left alone.
        $helper = @($g.Group | Where-Object { $pp = $byId[$parentOf[$_.Id]]; $pp -and ($windowed[$pp.Name] -or $pp.Id -eq $PID) })
        if ($helper.Count -eq $g.Count) { continue }
        $path = ($g.Group | Where-Object Path | Select-Object -First 1).Path
        if ($path -and $path.StartsWith($env:SystemRoot, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $known = $BgKnown[$name]
        $desc = if ($known) { $known.Label } else { ($g.Group | Where-Object Description | Select-Object -First 1).Description }
        $parents = @($g.Group | ForEach-Object { $pp = $byId[$parentOf[$_.Id]]; if ($pp -and $pp.Name -ne $name) { $pp.Name } } | Select-Object -Unique)
        $entries[$name] = [pscustomobject]@{
            Name        = $name
            Label       = if ($desc) { $desc } else { $name }
            Note        = if ($known) { $known.Note }
                          elseif ($parents -and $parents -notcontains 'explorer') { "Helper started by $(($parents | ForEach-Object { "$_.exe" }) -join ', ')" }
                          elseif ($path) { $path } else { "$name.exe" }
            Recommended = [bool]($known -and $known.End)
            Known       = [bool]$known
            MB          = [math]::Round(($g.Group | Measure-Object WorkingSet64 -Sum).Sum / 1MB)
            Ids         = @($g.Group.Id)
            Parent      = if ($parents.Count -eq 1) { $parents[0] } else { $null }
        }
    }
    # Unknown helper processes are folded into the app that started them...
    foreach ($key in @($entries.Keys)) {
        $e = $entries[$key]
        if ($e.Known -or -not $e.Parent -or -not $entries.Contains($e.Parent)) { continue }
        $owner = $entries[$e.Parent]
        $owner.MB += $e.MB; $owner.Ids += $e.Ids
        $entries.Remove($key)
    }
    # ...and known apps made of several processes (e.g. Epic, Medal) show as one entry.
    foreach ($grp in $entries.Values | Group-Object Label) {
        if ($grp.Count -eq 1 -or -not $grp.Group[0].Known) { $grp.Group; continue }
        $first = $grp.Group[0]
        $first.MB = ($grp.Group | Measure-Object MB -Sum).Sum
        $first.Ids = @($grp.Group | ForEach-Object { $_.Ids })
        $first.Recommended = -not @($grp.Group | Where-Object { -not $_.Recommended })
        $first
    }
}

$BgChecks = New-Object System.Collections.Generic.List[object]
function Update-Background {
    $apps = @(Get-BackgroundApps)
    $ui.BgPanel.Children.Clear(); $BgChecks.Clear()
    $groups = @(
        @{ Title = 'Recommended to end'; Items = @($apps | Where-Object Recommended | Sort-Object MB -Descending) }
        @{ Title = 'Other background apps - end only if you know you don''t need them'; Items = @($apps | Where-Object { -not $_.Recommended } | Sort-Object @{ e = 'Known'; Descending = $true }, @{ e = 'MB'; Descending = $true }) }
    )
    foreach ($grp in $groups) {
        if (-not $grp.Items) { continue }
        $h = New-TextLine $grp.Title -Muted
        $h.Margin = [System.Windows.Thickness]::new(0, 6, 0, 4)
        [void]$ui.BgPanel.Children.Add($h)
        foreach ($a in $grp.Items) {
            $stack = New-Object System.Windows.Controls.StackPanel
            $line = New-TextLine ('{0}  -  {1} MB' -f $a.Label, $a.MB)
            $line.Margin = [System.Windows.Thickness]::new(0)
            $note = New-TextLine $a.Note -Muted
            $note.FontSize = 11
            [void]$stack.Children.Add($line); [void]$stack.Children.Add($note)
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Content = $stack; $cb.Tag = $a; $cb.IsChecked = $a.Recommended
            $cb.Margin = [System.Windows.Thickness]::new(0, 2, 0, 4)
            [void]$ui.BgPanel.Children.Add($cb)
            $BgChecks.Add($cb)
        }
    }
    $total = ($apps | Measure-Object MB -Sum).Sum
    $rec = @($apps | Where-Object Recommended)
    $ui.TxtBgSummary.Text = if ($apps) {
        '{0} background apps using {1:N0} MB. {2} can be ended safely ({3:N0} MB).' -f $apps.Count, $total, $rec.Count, (($rec | Measure-Object MB -Sum).Sum)
    } else { 'No unneeded background apps are running.' }
    if (-not $apps) { [void]$ui.BgPanel.Children.Add((New-TextLine 'Nothing to end right now.' -Color '#5FD38D')) }
    Update-StartupList
}

function Stop-BackgroundApps([object[]]$Apps) {
    $freed = 0
    foreach ($a in $Apps) {
        $failed = 0
        foreach ($id in $a.Ids) { try { Stop-Process -Id $id -Force -ErrorAction Stop } catch { if (Get-Process -Id $id -ErrorAction SilentlyContinue) { $failed++ } } }
        if ($failed) { Write-Log "  $($a.Label): $failed process(es) could not be ended." 'WARN' } else { Write-Log "  Ended $($a.Label) ($($a.MB) MB)"; $freed += $a.MB }
    }
    Write-Log ('Freed about {0:N0} MB of memory.' -f $freed)
}

$ui.BtnBgEnd.Add_Click({
    $picked = @((Get-Checked $BgChecks) | ForEach-Object Tag)
    if (-not $picked) { [System.Windows.MessageBox]::Show('Select at least one app to end.', $AppName) | Out-Null; return }
    Write-Log "=== End $($picked.Count) background app(s) ==="
    Stop-BackgroundApps $picked
    Start-Sleep -Milliseconds 500
    Update-Background
})
$ui.BtnBgRefresh.Add_Click({ Update-Background })

# ---------- Startup apps (same on/off switch as Task Manager's Startup tab) ----------
$StartupRecommend = '(?i)(OneDrive|Teams|Skype|Spotify|Discord|Steam|EpicGames|Adobe|Acrobat|CCleaner|MicrosoftEdgeAutoLaunch|GoogleUpdate|' +
    'Opera|Brave|iTunes|Overwolf|Medal|Dropbox|GoogleDrive|Ubisoft|EADesktop|EA app|Battle\.net|Riot|Zoom|Slack|WhatsApp|Telegram|Cortana|Copilot|' +
    'uTorrent|qBittorrent|Messenger|Phone Link|Widgets)'
$StartupApproved = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'

function Get-StartupItems {
    $sources = @(
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Approved = "HKCU:\$StartupApproved\Run"; Scope = 'You' }
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Approved = "HKLM:\$StartupApproved\Run"; Scope = 'All users' }
        @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = "HKLM:\$StartupApproved\Run32"; Scope = 'All users' }
    )
    foreach ($s in $sources) {
        if (-not (Test-Path $s.Path)) { continue }
        $key = Get-Item $s.Path
        foreach ($n in $key.GetValueNames()) {
            if (-not $n) { continue }
            [pscustomobject]@{ Name = $n; Command = [string]$key.GetValue($n); Approved = $s.Approved; Scope = $s.Scope }
        }
    }
    $folders = @(
        @{ Dir = [Environment]::GetFolderPath('Startup'); Approved = "HKCU:\$StartupApproved\StartupFolder"; Scope = 'You' }
        @{ Dir = [Environment]::GetFolderPath('CommonStartup'); Approved = "HKLM:\$StartupApproved\StartupFolder"; Scope = 'All users' }
    )
    foreach ($f in $folders) {
        Get-ChildItem -LiteralPath $f.Dir -File -ErrorAction SilentlyContinue | Where-Object Name -ne 'desktop.ini' | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; Command = $_.FullName; Approved = $f.Approved; Scope = $f.Scope }
        }
    }
}

function Test-StartupEnabled($Item) {
    $v = $null
    if (Test-Path $Item.Approved) { $v = (Get-Item $Item.Approved).GetValue($Item.Name) }
    if ($v -is [byte[]] -and $v.Length) { ($v[0] -band 1) -eq 0 } else { $true }
}

function Set-StartupEnabled($Item, [bool]$On) {
    $bytes = if ($On) { [byte[]](2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0) } else { [byte[]](@(3, 0, 0, 0) + [BitConverter]::GetBytes([DateTime]::Now.ToFileTime())) }
    Set-RegValue $Item.Approved $Item.Name $bytes 'Binary'
}

$StartupChecks = New-Object System.Collections.Generic.List[object]
function Update-StartupList {
    $ui.StartupPanel.Children.Clear(); $StartupChecks.Clear()
    $items = @(Get-StartupItems | Sort-Object Name)
    if (-not $items) { [void]$ui.StartupPanel.Children.Add((New-TextLine 'No startup apps found.' -Muted)); return }
    foreach ($it in $items) {
        $rec = "$($it.Name) $($it.Command)" -match $StartupRecommend
        $it | Add-Member -NotePropertyName Recommended -NotePropertyValue $rec -Force
        $stack = New-Object System.Windows.Controls.StackPanel
        $title = New-TextLine $it.Name
        $title.Margin = [System.Windows.Thickness]::new(0)
        $sub = New-TextLine ("{0}{1}" -f $(if ($rec) { 'Usually safe to turn off  -  ' } else { '' }), ($it.Command -replace '^"?([^"]+?\.(exe|lnk|url|bat|cmd))"?.*$', '$1')) -Muted
        $sub.FontSize = 11
        if ($rec) { $sub.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString('#FFB454') }
        [void]$stack.Children.Add($title); [void]$stack.Children.Add($sub)
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Style = $window.FindResource('Switch')
        $cb.Content = $stack; $cb.Tag = $it; $cb.IsChecked = Test-StartupEnabled $it
        $cb.ToolTip = "$($it.Command)`nStarts for: $($it.Scope)"
        $cb.Add_Click({
            param($s, $e)
            try {
                Set-StartupEnabled $s.Tag ([bool]$s.IsChecked)
                Write-Log ('Start with Windows - {0}: {1}' -f $s.Tag.Name, $(if ($s.IsChecked) { 'On' } else { 'Off' }))
            } catch { Write-Log "$($s.Tag.Name): $($_.Exception.Message)" 'ERROR'; $s.IsChecked = -not $s.IsChecked }
        })
        [void]$ui.StartupPanel.Children.Add($cb)
        $StartupChecks.Add($cb)
    }
}

$ui.BtnStartupRecommended.Add_Click({
    $targets = @($StartupChecks | Where-Object { $_.Tag.Recommended -and $_.IsChecked })
    if (-not $targets) { [System.Windows.MessageBox]::Show('No recommended startup apps are turned on.', $AppName) | Out-Null; return }
    $names = ($targets | ForEach-Object { $_.Tag.Name }) -join "`n"
    $ok = [System.Windows.MessageBox]::Show("Stop these from starting with Windows?`n`n$names`n`nThey still work when you open them, and you can switch them back on here.", $AppName, 'YesNo', 'Question')
    if ($ok -ne 'Yes') { return }
    foreach ($cb in $targets) { Set-StartupEnabled $cb.Tag $false; $cb.IsChecked = $false; Write-Log "Start with Windows - $($cb.Tag.Name): Off" }
})

# Load each tab's live data when it is opened (keeps startup fast).
$ui.Tabs.Add_SelectionChanged({
    param($s, $e)
    if ($e.OriginalSource -ne $ui.Tabs) { return }   # ignore lists and combo boxes inside the tabs
    switch ([string]$ui.Tabs.SelectedItem.Header) {
        'Background' { Update-Background }
        'Display' { if (-not $script:DisplaysLoaded) { Show-Displays } }
        'Peripherals' { if (-not $script:PeriphLoaded) { Show-Peripherals } }
    }
})
$ui.BtnQuickBackground.Add_Click({ $ui.Tabs.SelectedItem = $ui.TabBackground })
#endregion

#region Start ---------------------------------------------------------------------------
Write-Log "$AppName v$AppVersion ready. Logs and undo backups: $DataDir"
if ($SelfTest) {
    Write-Host ("SelfTest OK: {0} named controls, {1} apps, {2} tweaks, {3} toggles, {4} features, {5} games" -f `
        $ui.Count, $AppChecks.Count, $TweakChecks.Count, $Toggles.Count, $FeatureChecks.Count, $Games.Count)
    foreach ($g in $Games) { Write-Host "  $($g.Name): $($g.Status.Text)" }
    $missing = @($ui.Keys | Where-Object { -not $ui[$_] })
    if ($missing) { Write-Host "Missing controls: $($missing -join ', ')"; exit 1 }

    # Run the startup job through the real runspace runner and dispatcher timer.
    $timer.Start()
    Start-InfoRefresh
    $deadline = (Get-Date).AddSeconds(90)
    while ($sync.Job -and (Get-Date) -lt $deadline) {
        $frame = New-Object System.Windows.Threading.DispatcherFrame
        $pump = New-Object System.Windows.Threading.DispatcherTimer
        $pump.Interval = [TimeSpan]::FromMilliseconds(200)
        $pump.Add_Tick({ $pump.Stop(); $frame.Continue = $false })
        $pump.Start()
        [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    }
    $timer.Stop()
    $line = $null; while ($sync.Log.TryDequeue([ref]$line)) { if ($line -match 'ERROR|WARN') { Write-Host "  log: $line" } }
    $ok = -not $sync.Job -and $ui.InfoPanel.Children.Count -gt 1 -and $ui.HwPanel.Children.Count -gt 0
    Write-Host ("  Background job: {0} ({1} info cards, {2} hardware cards)" -f $(if ($ok) { 'OK' } else { 'FAILED' }), $ui.InfoPanel.Children.Count, $ui.HwPanel.Children.Count)
    if (-not $ok) { exit 1 }

    # Macros: compile the engine; import a v1.2.0-style file (waits stored on each step, a bogus step that must be
    # dropped); check it becomes separate Delay steps; round-trip it; start/stop hooks. No input is sent.
    if (-not (Initialize-MacroEngine)) { Write-Host '  Macro engine: FAILED to compile'; exit 1 }
    $sample = '{"PeakMacros":1,"Macros":[{"Name":"Test","Hotkey":"F6","Repeat":3,"Speed":2,"Events":[' +
        '{"T":0,"Type":"KeyDown","Key":70},{"T":10,"Type":"KeyUp","Key":70},{"T":10,"Type":"MouseDown","Button":"Left"},' +
        '{"T":10,"Type":"MouseUp","Button":"Left"},{"T":5,"Type":"RunCommand","Key":1}]}]}'
    $tmp = Join-Path $env:TEMP 'peak-macro-selftest.json'
    Set-Content -Path $tmp -Value $sample -Encoding UTF8
    $m = @(Read-MacroFile $tmp)[0]
    $em = ConvertTo-EngineMacro $m
    Set-Content -Path $tmp -Value (ConvertTo-Json -InputObject @{ PeakMacros = 2; Macros = @($m) } -Depth 6) -Encoding UTF8
    $again = @(Read-MacroFile $tmp)[0]
    Remove-Item $tmp -ErrorAction SilentlyContinue
    $listing = @($again.Events | ForEach-Object { (Format-MacroStep $_) -replace '\s+', ' ' }) -join ' | '
    $expected = 'f Hold | 0.01 Delay | f Release | 0.01 Delay | {LMouse} Hold | 0.01 Delay | {LMouse} Release'
    [Peak.MacroEngine]::Enable(); $on = [Peak.MacroEngine]::HooksActive
    [Peak.MacroEngine]::Disable(); $off = -not [Peak.MacroEngine]::HooksActive
    $macroOk = $em.Events.Count -eq 7 -and $listing -eq $expected -and $again.HotkeyVk -eq 0x75 -and $again.Speed -eq 2 -and $again.Repeat -eq 3 -and $on -and $off
    Write-Host ("  Macros: {0} (hooks on={1} off={2})" -f $(if ($macroOk) { 'OK' } else { 'FAILED' }), $on, $off)
    Write-Host "    steps: $listing"
    if (-not $macroOk) { exit 1 }

    # Drive the macro editor through its real buttons, saving to a temp file (the user's macros are untouched).
    $MacroFile = Join-Path $env:TEMP 'peak-macro-editor-test.json'
    $Macros.Clear(); Update-MacroList; Open-Draft
    $click = { param($b) $b.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
    & $click $ui.BtnMacroNew
    $ui.TxtMacroName.Text = 'Editor test'
    Add-MacroSteps @((New-Step 'KeyDown' -Key 0x46), (New-Step 'KeyUp' -Key 0x46))     # what Insert > Key press adds for F
    $ui.LstMacroSteps.SelectedIndex = 0
    $ui.TxtDelay.Text = '0.25'; Invoke-InsertItem @{ Kind = 'Delay' }                    # delay after "f Hold"
    Invoke-InsertItem @{ Kind = 'Click'; Button = 'Right' }                              # appended after the delay
    $ui.LstMacroSteps.SelectedIndex = 1; $ui.TxtDelay.Text = '0.5'                       # edit the selected delay
    $ui.LstMacroSteps.SelectedIndex = 4; & $click $ui.BtnMacroUp                         # "f Release" moves above "{RMouse} Release"
    $ui.LstMacroSteps.SelectedIndex = 3; & $click $ui.BtnMacroDeleteStep                 # delete "f Release"
    $ui.RbMacroRepeat.IsChecked = $true; $ui.TxtRepeatCount.Text = '5'
    $script:KeyCapture = 'Bind'; $script:Draft.HotkeyVk = 0x75; $script:KeyCapture = $null   # Bind to Key result (F6)
    $dirtyBeforeSave = $script:DraftDirty
    & $click $ui.BtnMacroSave
    $saved = @(Read-MacroFile $MacroFile)[0]
    $savedSteps = @($saved.Events | ForEach-Object { (Format-MacroStep $_) -replace '\s+', ' ' }) -join ' | '
    $script:Draft.Name = 'should be discarded'; Set-DraftDirty $true; & $click $ui.BtnMacroCancel
    Remove-Item $MacroFile -ErrorAction SilentlyContinue
    $editorOk = $dirtyBeforeSave -and -not $script:DraftDirty -and $saved.Name -eq 'Editor test' -and $saved.Repeat -eq 5 -and $saved.HotkeyVk -eq 0x75 -and
        $savedSteps -eq 'f Hold | 0.5 Delay | {RMouse} Hold | {RMouse} Release' -and $script:Draft.Name -eq 'Editor test' -and $ui.LstMacros.Items[0] -like 'Editor test*F6*'
    Write-Host ("  Macro editor: {0}" -f $(if ($editorOk) { 'OK' } else { 'FAILED' }))
    Write-Host "    saved: $($saved.Name) / repeat $($saved.Repeat) / key $(Get-KeyName $saved.HotkeyVk) / $savedSteps"
    if (-not $editorOk) { exit 1 }

    # Display / Peripherals / Background: read-only checks. The display mode is only validated (CDS_TEST), never changed.
    if (-not (Initialize-Native)) { Write-Host '  Native helper: FAILED to compile'; exit 1 }
    Show-Displays
    $displays = @([Peak.Native]::GetDisplays())
    $modeTest = @($displays | ForEach-Object { [Peak.Native]::SetMode($_.Device, $_.Width, $_.Height, $_.Hz, $true) })
    foreach ($d in $displays) { Write-Host ("    display {0}: {1}x{2} @ {3} Hz, {4} modes, max {5} Hz" -f $d.Device, $d.Width, $d.Height, $d.Hz, $d.Modes.Count, ($d.Modes | Measure-Object Hz -Maximum).Maximum) }
    Show-Peripherals
    Write-Host ("    mouse speed {0}, accel {1}, scroll {2}, double-click {3} ms; key delay {4}, rate {5}; devices listed {6}" -f [Peak.Native]::MouseSpeed, [Peak.Native]::MouseAcceleration,
        [Peak.Native]::ScrollLines, [Peak.Native]::DoubleClickTime, [Peak.Native]::KeyboardDelay, [Peak.Native]::KeyboardSpeed, $ui.DevicePanel.Children.Count)
    $pendingAfterLoad = $PeriphPending.Count
    Update-Background
    $bg = @(Get-BackgroundApps)
    Write-Host "    background: $($ui.TxtBgSummary.Text)"
    foreach ($a in $bg | Sort-Object Recommended, MB -Descending | Select-Object -First 12) { Write-Host ("      [{0}] {1} - {2} MB" -f $(if ($a.Recommended) { 'x' } else { ' ' }), $a.Label, $a.MB) }
    $startup = @(Get-StartupItems)
    Write-Host ("    startup apps: {0} ({1} on, {2} flagged as usually safe to turn off)" -f $startup.Count, @($StartupChecks | Where-Object IsChecked).Count, @($StartupChecks | Where-Object { $_.Tag.Recommended }).Count)
    $sysOk = $displays.Count -gt 0 -and $ui.DisplayPanel.Children.Count -eq $displays.Count -and -not @($modeTest | Where-Object { $_ -ne 0 }) -and
        $pendingAfterLoad -eq 0 -and $ui.DevicePanel.Children.Count -gt 0 -and $ui.StartupPanel.Children.Count -gt 0
    Write-Host ("  Display / Peripherals / Background: {0}" -f $(if ($sysOk) { 'OK' } else { 'FAILED' }))
    if (-not $sysOk) { exit 1 }
    exit 0
}
$timer.Start()
Start-InfoRefresh
[void]$window.ShowDialog()
$timer.Stop()
#endregion
