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
$AppVersion = '1.1.0'

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
            if ($s -and $s -match '[A-Za-z]{2}' -and $s -notmatch '[▀-▟]' -and $s -notmatch '\[=+|\d+(\.\d+)?%') { $s }
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
)
$TweakMap = @{}
foreach ($t in $Tweaks) { $TweakMap[$t.Id] = $t }

$Presets = @{
    Standard = @('RestorePoint', 'TempFiles', 'Telemetry', 'ActivityHistory', 'Location', 'GameDVR', 'ConsumerFeatures', 'WifiSense', 'EndTask', 'ServicesManual', 'PS7Telemetry', 'DiskCleanup')
    Minimal  = @('RestorePoint', 'Telemetry', 'ActivityHistory', 'ConsumerFeatures', 'WifiSense', 'PS7Telemetry', 'EndTask')
    Gaming   = @('RestorePoint', 'TempFiles', 'Telemetry', 'ActivityHistory', 'Location', 'GameDVR', 'ConsumerFeatures', 'WifiSense', 'EndTask', 'ServicesManual', 'PS7Telemetry', 'BackgroundApps', 'UltimatePower', 'GamingNetwork', 'FSO', 'OemSoftware')
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
        Desc = 'Low shadows, shading, effects, post-processing, foliage, reflections, global illumination and anti-aliasing; V-Sync, motion blur, grass and Nanite off; mouse acceleration off. View distance and textures are left as you set them.'
        FindConfig = { $p = "$env:LOCALAPPDATA\FortniteGame\Saved\Config\WindowsClient\GameUserSettings.ini"; if (Test-Path $p) { $p } }
        FindExe = { Get-EpicGameDirs 'Fortnite' | ForEach-Object { Join-Path $_ 'FortniteGame\Binaries\Win64\FortniteClient-Win64-Shipping.exe' } | Where-Object { Test-Path -LiteralPath $_ } }
        Settings = @{
            'ScalabilityGroups' = @{
                'sg.ShadowQuality' = '0'; 'sg.GlobalIlluminationQuality' = '0'; 'sg.ReflectionQuality' = '0'; 'sg.PostProcessQuality' = '0'
                'sg.EffectsQuality' = '0'; 'sg.FoliageQuality' = '0'; 'sg.ShadingQuality' = '0'; 'sg.AntiAliasingQuality' = '0'
            }
            '/Script/FortniteGame.FortGameUserSettings' = @{
                'bUseVSync' = 'False'; 'bMotionBlur' = 'False'; 'bShowGrass' = 'False'; 'bUseNanite' = 'False'; 'bDisableMouseAcceleration' = 'True'
            }
        }
    }
    @{ Id = 'Rust'; Name = 'Rust'; Format = 'Cfg'
        Process = @('RustClient')
        Desc = 'Turns off V-Sync, motion blur, ambient occlusion, bloom, lens dirt, vignette, sun shafts, depth of field, volumetric clouds, grass displacement, contact shadows and gibs; lowest shadow-light and water quality; 1 queued frame for lower input lag.'
        FindConfig = { Get-SteamGameDirs 'Rust' | ForEach-Object { Join-Path $_ 'cfg\client.cfg' } | Where-Object { Test-Path -LiteralPath $_ } }
        FindExe = { Get-SteamGameDirs 'Rust' | ForEach-Object { Join-Path $_ 'RustClient.exe' } | Where-Object { Test-Path -LiteralPath $_ } }
        Settings = @{
            'graphics.vsync' = '0'; 'effects.motionblur' = 'False'; 'effects.ao' = 'False'; 'effects.bloom' = 'False'; 'effects.lensdirt' = 'False'
            'effects.vignet' = 'False'; 'effects.shafts' = 'False'; 'graphics.dof' = 'False'; 'graphics.volumetric_clouds' = '0'
            'grass.displacement' = 'False'; 'graphics.contactshadows' = 'False'; 'effects.maxgibs' = '0'; 'graphics.shadowlights' = '0'
            'water.quality' = '0'; 'water.reflections' = '0'; 'graphics.maxqueuedframes' = '1'
        }
    }
    @{ Id = 'Siege'; Name = 'Rainbow Six Siege'; Format = 'Ini'
        Process = @('RainbowSix', 'RainbowSix_Vulkan', 'RainbowSix_BE')
        Desc = 'V-Sync, letterbox and lens effects off; lowest reflections; raw mouse input on. Shadows are left alone (they show enemy positions). Applied to every Ubisoft profile on this PC.'
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
        # Siege's section names have changed between seasons, so these keys match in any section.
        Settings = @{
            '*' = @{
                'VSync' = '0'; 'UseLetterbox' = '0'; 'LensEffects' = '0'; 'Reflection' = '0'; 'RawInputMouseKeyboard' = '1'
                # Names used by older seasons.
                'AmbientOcclusion' = '0'; 'ZoomInDepthOfField' = '0'; 'ReflectionQuality' = '0'
            }
        }
    }
)

$GpuPrefKey = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'

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

function Invoke-GameOptimize($Game) {
    if (Test-GameRunning $Game) { return }
    $files = @(& $Game.FindConfig)
    if (-not $files) {
        Write-Log "$($Game.Name): settings file not found. Launch the game once, change any setting, close it, then try again." 'WARN'
        return
    }
    Write-Log "=== Optimize $($Game.Name) ==="
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
            $count = Update-ConfigFile -Path $f -Format $Game.Format -Settings $Game.Settings
            Write-Log "  ${f}: $count setting(s) changed"
        } catch { Write-Log "  ${f}: $($_.Exception.Message)" 'ERROR' }
    }
    foreach ($exe in @(& $Game.FindExe)) {
        $manifest.Gpu += @{ Exe = $exe; Old = (Get-RegValue $GpuPrefKey $exe) }
        Set-RegValue $GpuPrefKey $exe 'GpuPreference=2;' 'String'
        Write-Log "  Windows graphics preference set to High performance for $(Split-Path $exe -Leaf)"
    }
    $manifest | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $dir 'manifest.json') -Encoding UTF8
    Write-Log "$($Game.Name) optimized. Backup: $dir"
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
    <Style x:Key="Card" TargetType="Border">
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
                  <TextBlock Style="{StaticResource H}" Text="Advanced Tweaks" Margin="0"/>
                  <TextBlock Text="Caution: read each tooltip before selecting." Foreground="#FFB454" FontSize="12" Margin="0,2,0,8"/>
                </StackPanel>
                <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="AdvancedPanel"/></ScrollViewer>
              </DockPanel>
            </Border>
            <Border Grid.Column="2" Style="{StaticResource Card}" Margin="0,0,0,10">
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

    $job = $sync.Job
    if ($job -and $job.Handle.IsCompleted) {
        $sync.Job = $null
        try { [void]$job.PS.EndInvoke($job.Handle) } catch { Write-Log $_.Exception.Message 'ERROR' }
        foreach ($e in $job.PS.Streams.Error) { Write-Log $e.ToString() 'ERROR' }
        $job.PS.Dispose(); $job.RS.Dispose()
        $sync.Busy = $false
        if ($job.OnComplete) { try { & $job.OnComplete } catch { Write-Log $_.Exception.Message 'ERROR' } }
        Write-Log "=== Finished: $($job.Title) ==="
        $ui.TxtStatus.Text = "Ready - last task: $($job.Title)"
        $ui.Progress.IsIndeterminate = $false
        $ui.Progress.Visibility = 'Hidden'
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
    $cb = New-Check $t.Name $t.Desc $t.Id
    $panel = if ($t.Group -eq 'Essential') { $ui.EssentialPanel } else { $ui.AdvancedPanel }
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
    $desc.Text = $g.Desc
    $desc.TextWrapping = 'Wrap'
    $desc.Style = $window.FindResource('Muted')
    $buttons = New-Object System.Windows.Controls.WrapPanel
    $buttons.Margin = [System.Windows.Thickness]::new(-4, 10, 0, 0)
    $apply = New-Object System.Windows.Controls.Button
    $apply.Content = 'Optimize'; $apply.Style = $window.FindResource('AccentButton')
    $restore = New-Object System.Windows.Controls.Button
    $restore.Content = 'Restore Original'
    $open = New-Object System.Windows.Controls.Button
    $open.Content = 'Open Folder'
    foreach ($b in $apply, $restore, $open) { $b.Tag = $g; [void]$buttons.Children.Add($b) }
    $apply.Add_Click({ param($s, $e); Invoke-GameOptimize $s.Tag; Update-GameStatus $s.Tag })
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
    foreach ($c in $status, $desc, $buttons) { [void]$card.Child.Children.Add($c) }
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

function Start-InfoRefresh {
    Start-PeakJob -Title 'Read system info' -Script {
        $os = Get-CimInstance Win32_OperatingSystem
        $cs = Get-CimInstance Win32_ComputerSystem
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        $gpu = (Get-CimInstance Win32_VideoController | ForEach-Object Name) -join ', '
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
        $ver = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $up = (Get-Date) - $os.LastBootUpTime
        $sync.Result = [ordered]@{
            'Operating System' = '{0} {1} (build {2}.{3})' -f $os.Caption, $ver.DisplayVersion, $os.BuildNumber, $ver.UBR
            'Processor'        = '{0} - {1} cores / {2} threads' -f $cpu.Name.Trim(), $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors
            'Graphics'         = $gpu
            'Memory'           = '{0:N1} GB total, {1:N1} GB free' -f ($cs.TotalPhysicalMemory / 1GB), ($os.FreePhysicalMemory * 1KB / 1GB)
            'System Drive'     = '{0} {1:N0} GB free of {2:N0} GB' -f $env:SystemDrive, ($disk.FreeSpace / 1GB), ($disk.Size / 1GB)
            'Uptime'           = '{0}d {1}h {2}m' -f $up.Days, $up.Hours, $up.Minutes
            'Device'           = '{0} {1}' -f $cs.Manufacturer, $cs.Model
            'Power Plan'       = ((powercfg.exe /getactivescheme) -replace '^.*\((.*)\)\s*$', '$1')
        }
    } -OnComplete {
        if (-not $sync.Result) { return }
        $ui.InfoPanel.Children.Clear()
        foreach ($k in $sync.Result.Keys) {
            $card = New-Object System.Windows.Controls.Border
            $card.Style = $window.FindResource('Card')
            $card.Width = 345
            $stack = New-Object System.Windows.Controls.StackPanel
            $label = New-Object System.Windows.Controls.TextBlock
            $label.Text = $k.ToUpper(); $label.FontSize = 11; $label.Style = $window.FindResource('Muted')
            $value = New-Object System.Windows.Controls.TextBlock
            $value.Text = $sync.Result[$k]; $value.FontSize = 14; $value.TextWrapping = 'Wrap'
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
        if ($ok -ne 'Yes') { $e.Cancel = $true }
    }
})
#endregion

#region Start ---------------------------------------------------------------------------
Write-Log "$AppName v$AppVersion ready. Logs and undo backups: $DataDir"
if ($SelfTest) {
    Write-Host ("SelfTest OK: {0} named controls, {1} apps, {2} tweaks, {3} toggles, {4} features, {5} games" -f `
        $ui.Count, $AppChecks.Count, $TweakChecks.Count, $Toggles.Count, $FeatureChecks.Count, $Games.Count)
    foreach ($g in $Games) { Write-Host "  $($g.Name): $($g.Status.Text)" }
    $missing = @($ui.Keys | Where-Object { -not $ui[$_] })
    if ($missing) { Write-Host "Missing controls: $($missing -join ', ')"; exit 1 }
    exit 0
}
$timer.Start()
Start-InfoRefresh
[void]$window.ShowDialog()
$timer.Stop()
#endregion
