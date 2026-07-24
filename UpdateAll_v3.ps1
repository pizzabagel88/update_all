#requires -Version 5.1
<#
System Update Script v3.1.1
Minimal reporting/output bugfix release:
- Fixes leaked boolean output from helper calls
- Fixes Python Packages final summary logic
- Leaves behavior otherwise unchanged from v3.1.0
#>

[CmdletBinding()]
param(
    [ValidateSet('Fast','Full','Drivers','All')]
    [string]$Mode = 'All',

    [switch]$AuditOnly,
    [switch]$PromptForRiskyActions,
    [switch]$SkipVendorUtilities,
    [switch]$SkipSteam,
    [switch]$SkipWindowsUpdate,
    [switch]$SkipWebLookup,
    [switch]$SkipWingetExport,
    [switch]$SkipInventory,
    [switch]$SkipWSL,
    [switch]$SkipDefender,
    [switch]$SkipOllama,
    [switch]$SkipApt,
    [switch]$SkipPowerShellHelp,
    [int]$LogRetentionDays = 30
)

$script:ScriptVersion = '3.2.0'
$ErrorActionPreference = 'Continue'
$script:StartTime = Get-Date
$script:LogRoot = Join-Path $env:USERPROFILE 'Desktop\Updater\logs'
$script:SnapshotRoot = Join-Path $env:USERPROFILE 'Desktop\Updater\snapshots'
$script:SectionResults = New-Object System.Collections.Generic.List[object]
$script:Capabilities = @{}
$script:Context = @{
    PendingRebootAtStart = $false
    PendingRebootAtEnd   = $false
    IsAdmin              = $false
}

if (-not (Test-Path $script:LogRoot)) {
    New-Item -ItemType Directory -Path $script:LogRoot -Force | Out-Null
}
if (-not (Test-Path $script:SnapshotRoot)) {
    New-Item -ItemType Directory -Path $script:SnapshotRoot -Force | Out-Null
}

$script:RunStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:LogFile = Join-Path $script:LogRoot ('update-log-' + $script:RunStamp + '.txt')

try {
    Start-Transcript -Path $script:LogFile -Force | Out-Null
} catch {}

function Write-BlankLine {
    Write-Host ''
}

function Write-Section {
    param([string]$Text)
    Write-BlankLine
    Write-Host $Text -ForegroundColor Yellow
}

function Write-Ok {
    param([string]$Text)
    Write-Host ('[OK] ' + $Text) -ForegroundColor Green
}

function Write-Warn {
    param([string]$Text)
    Write-Host ('[WARN] ' + $Text) -ForegroundColor Yellow
}

function Write-ExpectedWarn {
    param([string]$Text)
    Write-Host ('[WARN-EXPECTED] ' + $Text) -ForegroundColor DarkYellow
}

function Write-Info {
    param([string]$Text)
    Write-Host ('[INFO] ' + $Text) -ForegroundColor Cyan
}

function Write-Err {
    param([string]$Text)
    Write-Host ('[ERR] ' + $Text) -ForegroundColor Red
}

function Add-SectionResult {
    param(
        [string]$Name,
        [ValidateSet('Success','Partial','Skipped','ExpectedLimit','Failed','Audit')]
        [string]$Status,
        [string]$Details = ''
    )

    $existing = $script:SectionResults | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if ($existing) {
        $existing.Status = $Status
        $existing.Details = $Details
    } else {
        $script:SectionResults.Add([pscustomobject]@{
            Name    = $Name
            Status  = $Status
            Details = $Details
        }) | Out-Null
    }
}

function Test-IsAdmin {
    return ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-ExternalCommand {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$SuccessMessage,
        [string]$FailurePrefix,
        [switch]$AllowNonZero
    )

    try {
        & $FilePath @Arguments
        $exitCode = $LASTEXITCODE

        if ($AllowNonZero -or $exitCode -eq 0) {
            if ($SuccessMessage) { Write-Ok $SuccessMessage }
            return [pscustomobject]@{
                Success  = $true
                ExitCode = $exitCode
            }
        }

        Write-Err ($FailurePrefix + ' (exit code ' + $exitCode + ')')
        return [pscustomobject]@{
            Success  = $false
            ExitCode = $exitCode
        }
    } catch {
        Write-Err ($FailurePrefix + ' ' + $_)
        return [pscustomobject]@{
            Success  = $false
            ExitCode = $null
        }
    }
}

function Invoke-IfCommandExists {
    param(
        [string]$CommandName,
        [scriptblock]$Action,
        [string]$MissingMessage
    )

    if ($script:Capabilities.ContainsKey($CommandName) -and $script:Capabilities[$CommandName]) {
        & $Action
        return $true
    } else {
        if ($MissingMessage) {
            Write-Host ('  ' + $MissingMessage) -ForegroundColor Gray
        }
        return $false
    }
}

function Test-DotNetSdkInstalled {
    try {
        $dotnetSdk = & dotnet --list-sdks 2>$null
        if ($LASTEXITCODE -ne 0) { return $false }
        if (-not $dotnetSdk) { return $false }
        $sdkLines = @($dotnetSdk | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        return ($sdkLines.Count -gt 0)
    } catch {
        return $false
    }
}

function Test-PendingReboot {
    $reasons = New-Object System.Collections.Generic.List[string]

    try {
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
            $reasons.Add('Component Based Servicing') | Out-Null
        }
    } catch {}

    try {
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
            $reasons.Add('Windows Update Auto Update') | Out-Null
        }
    } catch {}

    try {
        $pending = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
        if ($pending) {
            $reasons.Add('PendingFileRenameOperations') | Out-Null
        }
    } catch {}

    try {
        $ccm = Invoke-WmiMethod -Namespace 'root\ccm\ClientSDK' -Class 'CCM_ClientUtilities' -Name 'DetermineIfRebootPending' -ErrorAction SilentlyContinue
        if ($ccm -and ($ccm.RebootPending -or $ccm.IsHardRebootPending)) {
            $reasons.Add('ConfigMgr ClientSDK') | Out-Null
        }
    } catch {}

    [pscustomobject]@{
        IsPending = ($reasons.Count -gt 0)
        Reasons   = ($reasons | Sort-Object -Unique)
    }
}

function Should-RunPhase {
    param([string]$Phase)

    switch ($Mode) {
        'All'     { return $true }
        'Fast'    { return ($Phase -in @('Core','Packages','Tools','Snapshots')) }
        'Full'    { return ($Phase -in @('Core','Packages','Tools','Windows','Snapshots')) }
        'Drivers' { return ($Phase -in @('Drivers','Snapshots','Core')) }
        default   { return $true }
    }
}

function Confirm-RiskyAction {
    param(
        [string]$Prompt,
        [switch]$DefaultNo
    )

    if (-not $PromptForRiskyActions) { return $true }
    $suffix = if ($DefaultNo) { ' [y/N]' } else { ' [Y/n]' }
    $answer = Read-Host ($Prompt + $suffix)
    if ([string]::IsNullOrWhiteSpace($answer)) {
        return (-not $DefaultNo)
    }
    return ($answer -match '^(y|yes)$')
}

function Get-CommandVersion {
    param(
        [string]$CommandName,
        [scriptblock]$VersionScript
    )

    if (-not ($script:Capabilities.ContainsKey($CommandName) -and $script:Capabilities[$CommandName])) {
        return $null
    }

    try {
        $result = & $VersionScript
        if ($result) {
            return (($result | Select-Object -First 1).ToString()).Trim()
        }
    } catch {}
    return $null
}

function Initialize-Capabilities {
    Write-Section '[0/20] Preflight checks, capability map, and housekeeping...'

    $script:Context.IsAdmin = Test-IsAdmin
    if ($script:Context.IsAdmin) {
        Write-Ok 'Running as administrator'
    } else {
        Write-Warn 'Not running as administrator'
    }

    Write-Host '  Checking for installed commands...' -ForegroundColor Gray
    foreach ($cmd in @('winget','python','choco','scoop','npm','pnpm','yarn','dotnet','cargo','poetry','uv','wsl','ollama')) {
        $script:Capabilities[$cmd] = [bool](Get-Command $cmd -ErrorAction SilentlyContinue)
    }

    try {
        Write-Host '  Cleaning up old logs and snapshots...' -ForegroundColor Gray
        Get-ChildItem -Path $script:LogRoot -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$LogRetentionDays) } |
            Remove-Item -Force -ErrorAction SilentlyContinue

        Get-ChildItem -Path $script:SnapshotRoot -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$LogRetentionDays) } |
            Remove-Item -Force -ErrorAction SilentlyContinue

        Write-Ok ('Old logs/snapshots older than ' + $LogRetentionDays + ' days cleaned up')
    } catch {
        Write-Warn ('Log/snapshot cleanup encountered an issue: ' + $_)
    }

    Write-Host '  Checking for pending reboot...' -ForegroundColor Gray
    $pending = Test-PendingReboot
    $script:Context.PendingRebootAtStart = $pending.IsPending
    if ($pending.IsPending) {
        Write-Warn ('Pending reboot detected at start: ' + ($pending.Reasons -join ', '))
    } else {
        Write-Ok 'No pending reboot detected at start'
    }

    Write-Host ('  Script version: ' + $script:ScriptVersion) -ForegroundColor Gray
    Write-Host ('  Mode: ' + $Mode) -ForegroundColor Gray
    Write-Host ('  AuditOnly: ' + [string]$AuditOnly) -ForegroundColor Gray
    Write-Host ('  PromptForRiskyActions: ' + [string]$PromptForRiskyActions) -ForegroundColor Gray
    Write-Host ('  SkipWebLookup: ' + [string]$SkipWebLookup) -ForegroundColor Gray

    Add-SectionResult -Name 'Preflight' -Status 'Success' -Details 'Capabilities mapped, retention applied, reboot state checked'
}

function Export-InventorySnapshots {
    if (-not (Should-RunPhase 'Snapshots')) { return }

    Write-Section '[1/20] Exporting inventory snapshots...'
    if ($AuditOnly) {
        Write-Info 'AuditOnly enabled. Inventory export skipped.'
        Add-SectionResult -Name 'Inventory Snapshots' -Status 'Audit' -Details 'Would export machine inventory and versions'
        return
    }

    $didInventory = $false
    $didWinget = $false

    if (-not $SkipInventory) {
        try {
            Write-Host '  Collecting system inventory...' -ForegroundColor Gray
            $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
            $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
            $baseBoard = Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction SilentlyContinue
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
            $gpus = Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue

            $inventory = [pscustomobject]@{
                Timestamp            = (Get-Date).ToString('s')
                ScriptVersion        = $script:ScriptVersion
                ComputerName         = $env:COMPUTERNAME
                IsAdmin              = $script:Context.IsAdmin
                PendingRebootAtStart = $script:Context.PendingRebootAtStart
                Manufacturer         = $computerSystem.Manufacturer
                Model                = $computerSystem.Model
                OSCaption            = $os.Caption
                OSVersion            = $os.Version
                OSBuildNumber        = $os.BuildNumber
                MotherboardVendor    = $baseBoard.Manufacturer
                MotherboardProduct   = $baseBoard.Product
                BIOSVersion          = $bios.SMBIOSBIOSVersion
                BIOSReleaseDate      = $bios.ReleaseDate
                GPUs                 = ($gpus | Select-Object -ExpandProperty Name) -join '; '
                WingetPresent        = $script:Capabilities['winget']
                PythonPresent        = $script:Capabilities['python']
                DotnetPresent        = $script:Capabilities['dotnet']
                DotnetSdkPresent     = $(if ($script:Capabilities['dotnet']) { Test-DotNetSdkInstalled } else { $false })
                CargoPresent         = $script:Capabilities['cargo']
                PoetryPresent        = $script:Capabilities['poetry']
                UvPresent            = $script:Capabilities['uv']
                NpmPresent           = $script:Capabilities['npm']
                PnpmPresent          = $script:Capabilities['pnpm']
                YarnPresent          = $script:Capabilities['yarn']
                ChocoPresent         = $script:Capabilities['choco']
                ScoopPresent         = $script:Capabilities['scoop']
                PythonVersion        = (Get-CommandVersion -CommandName 'python' -VersionScript { python --version 2>&1 })
                WingetVersion        = (Get-CommandVersion -CommandName 'winget' -VersionScript { winget --version 2>$null })
            }

            $inventoryPath = Join-Path $script:SnapshotRoot ('inventory-' + $script:RunStamp + '.json')
            $inventory | ConvertTo-Json -Depth 5 | Set-Content -Path $inventoryPath -Encoding UTF8
            Write-Ok ('Inventory snapshot saved: ' + $inventoryPath)
            $didInventory = $true
        } catch {
            Write-Warn ('Inventory snapshot failed: ' + $_)
        }
    } else {
        Write-Host '  Inventory snapshot skipped by parameter' -ForegroundColor Gray
    }

    if (-not $SkipWingetExport) {
        $didWingetExport = $false
        $null = Invoke-IfCommandExists -CommandName 'winget' -MissingMessage 'winget not found; export skipped' -Action {
            try {
                Write-Host '  Exporting winget package list...' -ForegroundColor Gray
                $exportPath = Join-Path $script:SnapshotRoot ('winget-export-' + $script:RunStamp + '.json')
                winget export -o $exportPath --accept-source-agreements | Out-Null
                if ($LASTEXITCODE -eq 0 -and (Test-Path $exportPath)) {
                    Write-Ok ('winget export saved: ' + $exportPath)
                    $didWingetExport = $true
                } else {
                    Write-Warn 'winget export did not complete successfully'
                }
            } catch {
                Write-Warn ('winget export failed: ' + $_)
            }
        }
        $didWinget = $didWingetExport
    } else {
        Write-Host '  winget export skipped by parameter' -ForegroundColor Gray
    }

    if ($didInventory -or $didWinget) {
        Add-SectionResult -Name 'Inventory Snapshots' -Status 'Success' -Details 'Inventory and/or winget export written'
    } else {
        Add-SectionResult -Name 'Inventory Snapshots' -Status 'Partial' -Details 'No snapshots written or partially skipped'
    }
}

function Update-WingetPackages {
    if (-not (Should-RunPhase 'Packages')) { return }

    Write-Section '[2/20] Updating WinGet sources and packages...'
    if ($AuditOnly) {
        Write-Info 'AuditOnly enabled. Would run winget source update, self-update, and upgrade --all.'
        Add-SectionResult -Name 'WinGet Packages' -Status 'Audit' -Details 'Would update sources, App Installer, and all packages'
        return
    }

    $commandPresent = $false
    $actions = New-Object System.Collections.Generic.List[object]

    $commandPresent = Invoke-IfCommandExists -CommandName 'winget' -MissingMessage 'winget not found (skipped)' -Action {
        $r1 = Invoke-ExternalCommand -FilePath 'winget' -Arguments @('source','update') -SuccessMessage 'winget sources updated' -FailurePrefix 'winget source update failed:'
        $actions.Add([pscustomobject]@{ Name='source update'; Success=$r1.Success; ExitCode=$r1.ExitCode }) | Out-Null

        $r2 = Invoke-ExternalCommand -FilePath 'winget' -Arguments @('upgrade','Microsoft.AppInstaller','--accept-source-agreements','--accept-package-agreements') -SuccessMessage 'winget/App Installer update attempted' -FailurePrefix 'winget self-update failed:' -AllowNonZero
        $actions.Add([pscustomobject]@{ Name='App Installer upgrade'; Success=$r2.Success; ExitCode=$r2.ExitCode }) | Out-Null

        Write-Host '  Checking for available package upgrades...' -ForegroundColor Gray
        $upgradeList = & winget list --upgrade-available --accept-source-agreements 2>$null
        if ($LASTEXITCODE -eq 0 -and $upgradeList) {
            $packageLines = @($upgradeList | Select-Object -Skip 2 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $packageCount = $packageLines.Count
            if ($packageCount -gt 0) {
                Write-Host "  Found $packageCount packages available for upgrade:" -ForegroundColor Cyan
                foreach ($line in $packageLines) {
                    Write-Host "    - $line" -ForegroundColor Gray
                }
                Write-Host '  Upgrading packages...' -ForegroundColor Cyan
                Write-Host '  This may take several minutes...' -ForegroundColor Gray
            } else {
                Write-Host '  No packages available for upgrade' -ForegroundColor Green
            }
        }

        $r3 = Invoke-ExternalCommand -FilePath 'winget' -Arguments @('upgrade','--all','--include-unknown','--accept-source-agreements','--accept-package-agreements','--silent') -SuccessMessage 'winget package updates completed' -FailurePrefix 'winget package update failed:'
        $actions.Add([pscustomobject]@{ Name='upgrade all'; Success=$r3.Success; ExitCode=$r3.ExitCode }) | Out-Null
    }

    if (-not $commandPresent) {
        Add-SectionResult -Name 'WinGet Packages' -Status 'Skipped' -Details 'winget not installed'
        return
    }

    $total = $actions.Count
    $successes = @($actions | Where-Object { $_.Success }).Count
    $failures = $total - $successes

    if ($total -eq 0) {
        Add-SectionResult -Name 'WinGet Packages' -Status 'Failed' -Details 'winget present, but no actions were tracked'
    } elseif ($failures -eq 0) {
        Add-SectionResult -Name 'WinGet Packages' -Status 'Success' -Details ($successes.ToString() + '/' + $total + ' actions succeeded')
    } elseif ($successes -gt 0) {
        $failedList = ($actions | Where-Object { -not $_.Success } | ForEach-Object { $_.Name + ' (exit ' + $_.ExitCode + ')' }) -join '; '
        Add-SectionResult -Name 'WinGet Packages' -Status 'Partial' -Details ($successes.ToString() + '/' + $total + ' actions succeeded; failed: ' + $failedList)
    } else {
        $failedList = ($actions | ForEach-Object { $_.Name + ' (exit ' + $_.ExitCode + ')' }) -join '; '
        Add-SectionResult -Name 'WinGet Packages' -Status 'Failed' -Details ('0/' + $total + ' actions succeeded; failed: ' + $failedList)
    }
}

function Update-PythonPackages {
    if (-not (Should-RunPhase 'Packages')) { return }

    Write-Section '[3/20] Updating pip and Python packages...'
    if ($AuditOnly) {
        Write-Info 'AuditOnly enabled. Would upgrade pip and inspect outdated Python packages.'
        Add-SectionResult -Name 'Python Packages' -Status 'Audit' -Details 'Would run pip upgrade and pip list --outdated'
        return
    }

    $commandPresent = $false
    $commandPresent = Invoke-IfCommandExists -CommandName 'python' -MissingMessage 'python not found (skipped)' -Action {
        $result = [pscustomobject]@{
            PipUpdated      = $false
            CheckSucceeded  = $false
            UpdatedPackages = 0
            Errors          = New-Object System.Collections.Generic.List[string]
            HadRetries      = $false
            OutdatedCount   = 0
        }

        try {
            Write-Host '  Upgrading pip...' -ForegroundColor Gray
            $pipOutput = & python -m pip install --upgrade pip 2>&1
            if (($pipOutput | Out-String) -match 'Retrying \(Retry') {
                $result.HadRetries = $true
            }
            $pipExit = $LASTEXITCODE
            if ($pipExit -eq 0) {
                Write-Ok 'pip updated'
                $result.PipUpdated = $true
            } else {
                Write-Err ('pip update failed (exit code ' + $pipExit + ')')
                $result.Errors.Add('pip update failed') | Out-Null
            }
        } catch {
            Write-Err ('pip update failed: ' + $_)
            $result.Errors.Add('pip update exception') | Out-Null
        }

        try {
            Write-Host '  Checking for outdated Python packages...' -ForegroundColor Gray
            $json = & python -m pip list --outdated --format=json 2>$null
            if ($LASTEXITCODE -eq 0) {
                $result.CheckSucceeded = $true

                $text = ($json | Out-String).Trim()
                if ([string]::IsNullOrWhiteSpace($text) -or $text -eq '[]') {
                    Write-Ok 'No outdated Python packages found'
                    $result.OutdatedCount = 0
                } else {
                    $parsed = $text | ConvertFrom-Json -ErrorAction Stop
                    $packages = @()

                    if ($parsed -is [System.Array]) {
                        $packages = @($parsed)
                    } elseif ($parsed) {
                        $packages = @($parsed)
                    }

                    $toUpdate = $packages | Where-Object {
                        $_ -and
                        $_.PSObject.Properties.Match('name').Count -gt 0 -and
                        -not [string]::IsNullOrWhiteSpace([string]$_.name)
                    } | ForEach-Object { [string]$_.name }

                    $result.OutdatedCount = $toUpdate.Count

                    if ($toUpdate.Count -eq 0) {
                        Write-Ok 'No outdated Python packages found'
                    } else {
                        Write-Host ("  Updating $($toUpdate.Count) packages in batch...") -ForegroundColor Gray
                        # Update all packages in a single pip call for better performance
                        & python -m pip install --upgrade $toUpdate
                        if ($LASTEXITCODE -eq 0) {
                            $result.UpdatedPackages = $toUpdate.Count
                            Write-Ok ("Python packages updated: $($toUpdate.Count)")
                        } else {
                            Write-Err "Batch Python package update failed. Attempting individual updates..."
                            foreach ($pkgName in $toUpdate) {
                                & python -m pip install --upgrade $pkgName
                                if ($LASTEXITCODE -eq 0) { $result.UpdatedPackages++ }
                                else { $result.Errors.Add("Failed: $pkgName") }
                            }
                        }
                    }
                }
            } else {
                Write-Err 'Failed to check for outdated Python packages'
                $result.Errors.Add('outdated package enumeration failed') | Out-Null
            }
        } catch {
            Write-Err ('Python package update failed: ' + $_)
            $result.Errors.Add('Python package update exception') | Out-Null
        }

        $script:PythonSectionResult = $result
    }

    if (-not $commandPresent) {
        Add-SectionResult -Name 'Python Packages' -Status 'Skipped' -Details 'python not installed'
        return
    }

    $result = $script:PythonSectionResult
    Remove-Variable -Name PythonSectionResult -Scope Script -ErrorAction SilentlyContinue

    if (-not $result) {
        Add-SectionResult -Name 'Python Packages' -Status 'Failed' -Details 'python present, but no result object was produced'
        return
    }

    if ($result.PipUpdated -and $result.CheckSucceeded -and $result.Errors.Count -eq 0) {
        if ($result.HadRetries) {
            Add-SectionResult -Name 'Python Packages' -Status 'Success' -Details ('pip updated after transient retries; package updates applied: ' + $result.UpdatedPackages)
        } else {
            Add-SectionResult -Name 'Python Packages' -Status 'Success' -Details ('pip updated; package updates applied: ' + $result.UpdatedPackages)
        }
    } elseif (($result.PipUpdated -or $result.CheckSucceeded) -and $result.Errors.Count -gt 0) {
        Add-SectionResult -Name 'Python Packages' -Status 'Partial' -Details (($result.Errors -join '; ') + '; packages updated: ' + $result.UpdatedPackages)
    } else {
        Add-SectionResult -Name 'Python Packages' -Status 'Failed' -Details 'python present, but pip update and package enumeration failed'
    }
}

function Update-WindowsAndDrivers {
    if (-not (Should-RunPhase 'Windows') -or $SkipWindowsUpdate) { return }

    Write-Section '[4/20] Updating Windows, Microsoft Update, and drivers...'

    if ($AuditOnly) {
        Write-Info 'AuditOnly enabled. Would install PSWindowsUpdate if needed and run Microsoft Update and driver passes.'
        Add-SectionResult -Name 'Windows Update' -Status 'Audit' -Details 'Would run Windows + Microsoft Update + drivers'
        return
    }

    try {
        if (-not (Test-IsAdmin)) {
            Write-Warn 'Not running as administrator. Windows Update and driver updates skipped.'
            Write-Host '  To enable this section, run the script as Administrator.' -ForegroundColor Gray
            Add-SectionResult -Name 'Windows Update' -Status 'Skipped' -Details 'Administrator privileges required'
            return
        }

        if (-not (Confirm-RiskyAction -Prompt 'Proceed with Windows Update install passes?' -DefaultNo)) {
            Write-Host '  Windows Update skipped by user choice' -ForegroundColor Gray
            Add-SectionResult -Name 'Windows Update' -Status 'Skipped' -Details 'Skipped by prompt'
            return
        }

        if (Get-Module -Name PSWindowsUpdate) {
            Remove-Module PSWindowsUpdate -Force -ErrorAction SilentlyContinue
        }

        if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
            Write-Host '  Installing PSWindowsUpdate module...' -ForegroundColor Gray
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser -ErrorAction SilentlyContinue | Out-Null
            Install-Module -Name PSWindowsUpdate -Force -Scope CurrentUser -AllowClobber -ErrorAction SilentlyContinue
        }

        if (Get-Module -ListAvailable -Name PSWindowsUpdate) {
            Import-Module PSWindowsUpdate -Force

            try {
                Add-WUServiceManager -MicrosoftUpdate -Confirm:$false | Out-Null
                Write-Ok 'Microsoft Update service registered'
            } catch {
                Write-Warn 'Microsoft Update service registration failed or already exists'
            }

            Write-Host '  Installing Windows and Microsoft updates...' -ForegroundColor Gray
            Write-Host '  This may take 10-30 minutes...' -ForegroundColor Gray
            Write-Host '  Please wait, do not interrupt...' -ForegroundColor Gray
            Get-WindowsUpdate -MicrosoftUpdate -AcceptAll -Install -AutoReboot -Confirm:$false

            try {
                Write-Host '  Running driver-focused Windows Update pass...' -ForegroundColor Gray
                Write-Host '  Checking for driver updates...' -ForegroundColor Gray
                Get-WindowsUpdate -MicrosoftUpdate -Category Drivers -AcceptAll -Install -AutoReboot -Confirm:$false
            } catch {
                Write-Warn 'Driver-focused Windows Update pass failed or no driver updates were available'
            }

            Write-Ok 'Windows Update pass completed'
            Add-SectionResult -Name 'Windows Update' -Status 'Success' -Details 'Windows and driver update passes completed'
        } else {
            Write-Warn 'PSWindowsUpdate installation failed. Skipping Windows Update.'
            Add-SectionResult -Name 'Windows Update' -Status 'Failed' -Details 'PSWindowsUpdate unavailable after install attempt'
        }
    } catch {
        Write-Err ('Windows Update failed: ' + $_)
        Add-SectionResult -Name 'Windows Update' -Status 'Failed' -Details $_.ToString()
    }
}

function Update-CommonPackageManagers {
    if (-not (Should-RunPhase 'Packages')) { return }

    Write-Section '[5/20] Updating Chocolatey, Scoop, npm, pnpm, and Yarn...'

    if ($AuditOnly) {
        Write-Info 'AuditOnly enabled. Would update detected package managers.'
        Add-SectionResult -Name 'Common Package Managers' -Status 'Audit' -Details 'Would update choco/scoop/npm/pnpm/yarn if present'
        return
    }

    Write-Host '  Checking for package managers...' -ForegroundColor Gray
    $actions = New-Object System.Collections.Generic.List[object]

    $null = Invoke-IfCommandExists -CommandName 'choco' -MissingMessage 'Chocolatey not found (skipped)' -Action {
        Write-Host '  Chocolatey found. Updating packages...' -ForegroundColor Gray
        & choco upgrade all -y
        $actions.Add([pscustomobject]@{ Name='Chocolatey'; Success=($LASTEXITCODE -eq 0); ExitCode=$LASTEXITCODE }) | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Ok 'Chocolatey packages updated' } else { Write-Err ('Chocolatey update failed (exit code ' + $LASTEXITCODE + ')') }
    }

    $null = Invoke-IfCommandExists -CommandName 'scoop' -MissingMessage 'Scoop not found (skipped)' -Action {
        Write-Host '  Scoop found. Updating packages...' -ForegroundColor Gray
        & scoop update '*'
        $actions.Add([pscustomobject]@{ Name='Scoop'; Success=($LASTEXITCODE -eq 0); ExitCode=$LASTEXITCODE }) | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Ok 'Scoop packages updated' } else { Write-Err ('Scoop update failed (exit code ' + $LASTEXITCODE + ')') }
    }

    $null = Invoke-IfCommandExists -CommandName 'npm' -MissingMessage 'npm not found (skipped)' -Action {
        Write-Host '  npm found. Updating global packages...' -ForegroundColor Gray
        & npm update -g
        $actions.Add([pscustomobject]@{ Name='npm'; Success=($LASTEXITCODE -eq 0); ExitCode=$LASTEXITCODE }) | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Ok 'npm global packages updated' } else { Write-Err ('npm update failed (exit code ' + $LASTEXITCODE + ')') }
    }

    $null = Invoke-IfCommandExists -CommandName 'pnpm' -MissingMessage 'pnpm not found (skipped)' -Action {
        Write-Host '  pnpm found. Updating global packages...' -ForegroundColor Gray
        & pnpm update -g
        $actions.Add([pscustomobject]@{ Name='pnpm'; Success=($LASTEXITCODE -eq 0); ExitCode=$LASTEXITCODE }) | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Ok 'pnpm global packages updated' } else { Write-Err ('pnpm update failed (exit code ' + $LASTEXITCODE + ')') }
    }

    $null = Invoke-IfCommandExists -CommandName 'yarn' -MissingMessage 'Yarn not found (skipped)' -Action {
        Write-Host '  Yarn found. Updating global packages...' -ForegroundColor Gray
        & yarn global upgrade
        $actions.Add([pscustomobject]@{ Name='Yarn'; Success=($LASTEXITCODE -eq 0); ExitCode=$LASTEXITCODE }) | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Ok 'Yarn global packages updated' } else { Write-Err ('Yarn update failed (exit code ' + $LASTEXITCODE + ')') }
    }

    $total = $actions.Count
    $successes = @($actions | Where-Object { $_.Success }).Count

    if ($total -eq 0) {
        Add-SectionResult -Name 'Common Package Managers' -Status 'Skipped' -Details 'No supported package managers found'
    } elseif ($successes -eq $total) {
        Add-SectionResult -Name 'Common Package Managers' -Status 'Success' -Details ($successes.ToString() + '/' + $total + ' managers updated')
    } elseif ($successes -gt 0) {
        Add-SectionResult -Name 'Common Package Managers' -Status 'Partial' -Details ($successes.ToString() + '/' + $total + ' managers updated')
    } else {
        Add-SectionResult -Name 'Common Package Managers' -Status 'Failed' -Details 'All detected manager updates failed'
    }
}

function Update-DotNetAndRust {
    if (-not (Should-RunPhase 'Tools')) { return }

    Write-Section '[6/20] Updating .NET and Rust tooling...'

    if ($AuditOnly) {
        Write-Info 'AuditOnly enabled. Would check for dotnet SDK before global tool updates and update Rust helpers if present.'
        Add-SectionResult -Name '.NET and Rust Tooling' -Status 'Audit' -Details 'Would check SDK and update tools'
        return
    }

    $dotnetStatus = 'Skipped'
    $dotnetDetails = 'dotnet not installed'

    if ($script:Capabilities['dotnet']) {
        Write-Host '  Checking for .NET SDK...' -ForegroundColor Gray
        if (Test-DotNetSdkInstalled) {
            Write-Host '  dotnet found and .NET SDK detected. Updating global tools...' -ForegroundColor Gray
            & dotnet tool update --all --global
            if ($LASTEXITCODE -eq 0) {
                Write-Ok '.NET global tools updated'
                $dotnetStatus = 'Success'
                $dotnetDetails = '.NET SDK detected; global tools updated'
            } else {
                Write-Warn '.NET built-in global tool update failed, trying dotnet-update-all-tools if available'
                if (Get-Command 'dotnet-update-all-tools' -ErrorAction SilentlyContinue) {
                    & dotnet-update-all-tools
                    if ($LASTEXITCODE -eq 0) {
                        Write-Ok 'dotnet-update-all-tools completed'
                        $dotnetStatus = 'Success'
                        $dotnetDetails = '.NET SDK detected; fallback helper completed'
                    } else {
                        Write-Err ('dotnet-update-all-tools failed (exit code ' + $LASTEXITCODE + ')')
                        $dotnetStatus = 'Partial'
                        $dotnetDetails = 'SDK detected; built-in and fallback helper failed'
                    }
                } else {
                    Write-Host '  dotnet-update-all-tools not found (skipped)' -ForegroundColor Gray
                    $dotnetStatus = 'Partial'
                    $dotnetDetails = 'SDK detected; built-in update failed and fallback helper absent'
                }
            }
        } else {
            Write-ExpectedWarn 'dotnet is present, but no .NET SDK is installed (runtime-only install detected). Skipping .NET global tool updates.'
            $dotnetStatus = 'ExpectedLimit'
            $dotnetDetails = 'dotnet runtime present without SDK'
        }
    } else {
        Write-Host '  dotnet not found (skipped)' -ForegroundColor Gray
    }

    $cargoStatus = 'Skipped'
    $cargoDetails = 'cargo not installed'

    $null = Invoke-IfCommandExists -CommandName 'cargo' -MissingMessage 'cargo not found (skipped)' -Action {
        Write-Host '  cargo found. Checking for cargo-install-update...' -ForegroundColor Gray
        Write-Host '  Checking Rust tooling...' -ForegroundColor Gray
        if (Get-Command 'cargo-install-update' -ErrorAction SilentlyContinue) {
            & cargo-install-update -a
            if ($LASTEXITCODE -eq 0) {
                Write-Ok 'Rust cargo-installed binaries updated'
                $cargoStatus = 'Success'
                $cargoDetails = 'cargo-install-update completed'
            } else {
                Write-Err ('cargo-install-update failed (exit code ' + $LASTEXITCODE + ')')
                $cargoStatus = 'Failed'
                $cargoDetails = 'cargo-install-update failed'
            }
        } else {
            Write-Host '  cargo-install-update not found. Installing helper...' -ForegroundColor Gray
            & cargo install cargo-update
            if ($LASTEXITCODE -eq 0 -and (Get-Command 'cargo-install-update' -ErrorAction SilentlyContinue)) {
                & cargo-install-update -a
                if ($LASTEXITCODE -eq 0) {
                    Write-Ok 'Rust cargo-installed binaries updated'
                    $cargoStatus = 'Success'
                    $cargoDetails = 'cargo-update helper installed and updates applied'
                } else {
                    Write-Err ('cargo-install-update failed (exit code ' + $LASTEXITCODE + ')')
                    $cargoStatus = 'Partial'
                    $cargoDetails = 'helper installed, update pass failed'
                }
            } else {
                Write-Warn 'Could not install cargo-update helper'
                $cargoStatus = 'Partial'
                $cargoDetails = 'cargo present; helper install failed'
            }
        }
    }

    $combined = @($dotnetStatus, $cargoStatus)
    if ($combined -contains 'Failed') {
        Add-SectionResult -Name '.NET and Rust Tooling' -Status 'Partial' -Details ($dotnetDetails + '; ' + $cargoDetails)
    } elseif ($combined -contains 'Partial') {
        Add-SectionResult -Name '.NET and Rust Tooling' -Status 'Partial' -Details ($dotnetDetails + '; ' + $cargoDetails)
    } elseif ($combined -contains 'ExpectedLimit') {
        Add-SectionResult -Name '.NET and Rust Tooling' -Status 'ExpectedLimit' -Details ($dotnetDetails + '; ' + $cargoDetails)
    } elseif (($combined | Where-Object { $_ -eq 'Skipped' }).Count -eq 2) {
        Add-SectionResult -Name '.NET and Rust Tooling' -Status 'Skipped' -Details 'Neither dotnet nor cargo available'
    } else {
        Add-SectionResult -Name '.NET and Rust Tooling' -Status 'Success' -Details ($dotnetDetails + '; ' + $cargoDetails)
    }
}

function Update-AdditionalPythonTools {
    if (-not (Should-RunPhase 'Tools')) { return }

    Write-Section '[7/20] Updating Poetry and uv if present...'

    if ($AuditOnly) {
        Write-Info 'AuditOnly enabled. Would self-update Poetry and uv if present.'
        Add-SectionResult -Name 'Additional Python Tools' -Status 'Audit' -Details 'Would self-update Poetry and uv'
        return
    }

    $actions = New-Object System.Collections.Generic.List[object]

    $null = Invoke-IfCommandExists -CommandName 'poetry' -MissingMessage 'Poetry not found (skipped)' -Action {
        Write-Host '  Poetry found. Self-updating...' -ForegroundColor Gray
        & poetry self update
        $actions.Add([pscustomobject]@{ Name='Poetry'; Success=($LASTEXITCODE -eq 0); ExitCode=$LASTEXITCODE }) | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Ok 'Poetry updated' } else { Write-Err ('Poetry update failed (exit code ' + $LASTEXITCODE + ')') }
    }

    $null = Invoke-IfCommandExists -CommandName 'uv' -MissingMessage 'uv not found (skipped)' -Action {
        Write-Host '  uv found. Self-updating...' -ForegroundColor Gray
        & uv self update
        $actions.Add([pscustomobject]@{ Name='uv'; Success=($LASTEXITCODE -eq 0); ExitCode=$LASTEXITCODE }) | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Ok 'uv updated' } else { Write-Err ('uv update failed (exit code ' + $LASTEXITCODE + ')') }
    }

    $total = $actions.Count
    $successes = @($actions | Where-Object { $_.Success }).Count

    if ($total -eq 0) {
        Add-SectionResult -Name 'Additional Python Tools' -Status 'Skipped' -Details 'Poetry and uv not found'
    } elseif ($successes -eq $total) {
        Add-SectionResult -Name 'Additional Python Tools' -Status 'Success' -Details ($successes.ToString() + '/' + $total + ' tools updated')
    } elseif ($successes -gt 0) {
        Add-SectionResult -Name 'Additional Python Tools' -Status 'Partial' -Details ($successes.ToString() + '/' + $total + ' tools updated')
    } else {
        Add-SectionResult -Name 'Additional Python Tools' -Status 'Failed' -Details 'All detected Python tool updates failed'
    }
}

function Update-Steam {
    if (-not (Should-RunPhase 'Drivers') -or $SkipSteam) { return }

    Write-Section '[8/20] Checking Steam...'

    if ($AuditOnly) {
        Write-Info 'AuditOnly enabled. Would locate and launch Steam with -silent.'
        Add-SectionResult -Name 'Steam' -Status 'Audit' -Details 'Would launch Steam for update checks'
        return
    }

    try {
        $steamPaths = @()
        if ($env:ProgramFiles) { $steamPaths += (Join-Path $env:ProgramFiles 'Steam\steam.exe') }
        if (${env:ProgramFiles(x86)}) { $steamPaths += (Join-Path ${env:ProgramFiles(x86)} 'Steam\steam.exe') }
        $steamPath = $steamPaths | Where-Object { Test-Path $_ } | Select-Object -First 1

        if ($steamPath) {
            if (-not (Confirm-RiskyAction -Prompt 'Launch Steam for background update checks?' -DefaultNo)) {
                Write-Host '  Steam launch skipped by user choice' -ForegroundColor Gray
                Add-SectionResult -Name 'Steam' -Status 'Skipped' -Details 'Skipped by prompt'
                return
            }
            Write-Host '  Steam found. Starting Steam to check for updates...' -ForegroundColor Gray
            Start-Process -FilePath $steamPath -ArgumentList '-silent' -NoNewWindow
            Write-Ok 'Steam launched for background update checks'
            Add-SectionResult -Name 'Steam' -Status 'Success' -Details 'Steam launched'
        } else {
            Write-Host '  Steam not found (skipped)' -ForegroundColor Gray
            Add-SectionResult -Name 'Steam' -Status 'Skipped' -Details 'Steam not installed'
        }
    } catch {
        Write-Err ('Steam update failed: ' + $_)
        Add-SectionResult -Name 'Steam' -Status 'Failed' -Details $_.ToString()
    }
}

function Update-VendorUtilities {
    if (-not (Should-RunPhase 'Drivers') -or $SkipVendorUtilities) { return }

    Write-Section '[9/20] Launching vendor update utilities if installed...'

    if ($AuditOnly) {
        Write-Info 'AuditOnly enabled. Would detect and launch installed vendor utilities.'
        Add-SectionResult -Name 'Vendor Utilities' -Status 'Audit' -Details 'Would launch installed vendor tools'
        return
    }

    if (-not (Confirm-RiskyAction -Prompt 'Launch installed vendor utilities?' -DefaultNo)) {
        Write-Host '  Vendor utilities skipped by user choice' -ForegroundColor Gray
        Add-SectionResult -Name 'Vendor Utilities' -Status 'Skipped' -Details 'Skipped by prompt'
        return
    }

    Write-Host '  Scanning for vendor utilities...' -ForegroundColor Gray
    $candidates = @(
        @{ Name='Dell Command Update'; Paths=@('C:\Program Files\Dell\CommandUpdate\dcu-cli.exe'); Args=@('/applyUpdates','-silent'); Match=$null },
        @{ Name='Lenovo System Update'; Paths=@('C:\Program Files (x86)\Lenovo\System Update\tvsu.exe'); Args=@('/CM','-search','A','-action','INSTALL','-includerebootpackages','1'); Match=$null },
        @{ Name='MyASUS'; Paths=@('C:\Program Files (x86)\ASUS\MyASUS\MyASUS.exe'); Args=@(); Match=$null },
        @{ Name='MSI Center'; Paths=@('C:\Program Files (x86)\MSI\One Dragon Center\OneDragonCenter.exe','C:\Program Files\MSI\MSI Center\MSI.CentralServer.exe'); Args=@(); Match=$null },
        @{ Name='Gigabyte Control Center'; Paths=@('C:\Program Files\GIGABYTE\Control Center\GCC.exe'); Args=@(); Match=$null },
        @{ Name='Samsung Magician'; Paths=@('C:\Program Files\Samsung\Samsung Magician\SamsungMagician.exe'); Args=@(); Match=$null },
        @{ Name='Western Digital Dashboard'; Paths=@('C:\Program Files\Western Digital\SSD Dashboard\WD SSD Dashboard.exe'); Args=@(); Match=$null },
        @{ Name='Crucial Storage Executive'; Paths=@('C:\Program Files\Crucial\Crucial Storage Executive\StorageExecutive.exe'); Args=@(); Match=$null },
        @{ Name='Intel Driver and Support Assistant'; Paths=@('C:\Program Files (x86)\Intel\Driver and Support Assistant\DSATray.exe'); Args=@(); Match='Intel|Arc' },
        @{ Name='AMD Software'; Paths=@('C:\Program Files\AMD\CNext\CNext\RadeonSoftware.exe'); Args=@(); Match='AMD|Radeon|RX' },
        @{ Name='NVIDIA App'; Paths=@('C:\Program Files\NVIDIA Corporation\NVIDIA app\CEF\NVIDIA App.exe'); Args=@(); Match='NVIDIA|GeForce|Quadro|RTX|GTX' },
        @{ Name='GeForce Experience'; Paths=@('C:\Program Files\NVIDIA Corporation\NVIDIA GeForce Experience\NVIDIA GeForce Experience.exe'); Args=@(); Match='NVIDIA|GeForce|Quadro|RTX|GTX' },
        @{ Name='Logitech G HUB'; Paths=@('C:\Program Files\LGHUB\lghub.exe'); Args=@(); Match=$null },
        @{ Name='Razer Synapse'; Paths=@('C:\Program Files (x86)\Razer\Synapse3\WPFUI\Framework\Razer Synapse 3 Host.exe'); Args=@(); Match=$null },
        @{ Name='SteelSeries GG'; Paths=@('C:\Program Files\SteelSeries\GG\SteelSeriesGG.exe'); Args=@(); Match=$null }
    )

    Write-Host '  Detecting GPU hardware...' -ForegroundColor Gray
    $gpuNames = @()
    try {
        $gpuNames = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch 'Virtual|Remote|Basic Display|Microsoft Hyper-V|Miracast|Indirect' } |
            Select-Object -ExpandProperty Name)
    } catch {}

    $found = 0
    $launched = 0

    foreach ($candidate in $candidates) {
        if ($candidate.Match -and $gpuNames.Count -gt 0) {
            $matchGpu = $false
            foreach ($gpuName in $gpuNames) {
                if ($gpuName -match $candidate.Match) {
                    $matchGpu = $true
                    break
                }
            }
            if (-not $matchGpu) {
                Write-Host ('  ' + $candidate.Name + ' skipped (not relevant to detected hardware)') -ForegroundColor Gray
                continue
            }
        }

        $hit = $candidate.Paths | Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($hit) {
            $found++
            try {
                Write-Host ('  Found ' + $candidate.Name + '. Launching...') -ForegroundColor Gray
                if ($candidate.Args.Count -gt 0) {
                    Start-Process -FilePath $hit -ArgumentList $candidate.Args -WindowStyle Minimized
                } else {
                    Start-Process -FilePath $hit -WindowStyle Minimized
                }
                Write-Ok ($candidate.Name + ' launched')
                $launched++
            } catch {
                Write-Err ($candidate.Name + ' launch failed: ' + $_)
            }
        } else {
            Write-Host ('  ' + $candidate.Name + ' not found (skipped)') -ForegroundColor Gray
        }
    }

    if ($found -eq 0) {
        Add-SectionResult -Name 'Vendor Utilities' -Status 'Skipped' -Details 'No matching vendor utilities found'
    } elseif ($launched -eq $found) {
        Add-SectionResult -Name 'Vendor Utilities' -Status 'Success' -Details ($launched.ToString() + '/' + $found + ' utilities launched')
    } elseif ($launched -gt 0) {
        Add-SectionResult -Name 'Vendor Utilities' -Status 'Partial' -Details ($launched.ToString() + '/' + $found + ' utilities launched')
    } else {
        Add-SectionResult -Name 'Vendor Utilities' -Status 'Failed' -Details 'Vendor utilities found but none launched successfully'
    }
}

function Get-NvidiaDisplayVersionFromWindowsVersion {
    param([string]$DriverVersion)

    if ([string]::IsNullOrWhiteSpace($DriverVersion)) { return $null }
    $digits = ($DriverVersion -replace '[^0-9]', '')
    if ($digits.Length -lt 5) { return $null }

    $last5 = $digits.Substring($digits.Length - 5)
    $major = $last5.Substring(0, $last5.Length - 2)
    $minor = $last5.Substring($last5.Length - 2)
    return ($major + '.' + $minor)
}

function Compare-VersionStrings {
    param(
        [string]$A,
        [string]$B
    )

    try {
        $va = [version](($A -replace '[^0-9\.]', ''))
        $vb = [version](($B -replace '[^0-9\.]', ''))
        return $va.CompareTo($vb)
    } catch {
        return $null
    }
}

function Get-LatestAsusBiosInfo {
    param([string]$BoardProduct)
    if ($SkipWebLookup) { return $null }

    # ASUS URLs usually follow a slug pattern based on the model name
    # Example: https://www.asus.com/motherboards-components/motherboards/all-series/PRIME-B760M-A-WIFI/helpdesk_bios/
    $slug = $BoardProduct -replace '\s+', '-'
    return [pscustomobject]@{
        SourceUrl     = "https://www.asus.com/search/results?searchType=support&searchKey=$($BoardProduct)&Tab=Drivers_And_Tools"
        DirectLink    = "https://www.asus.com/motherboards-components/motherboards/all-series/$slug/helpdesk_bios/"
        LatestVersion = $null # Parsing requires JS/Headless browser
        Note          = "ASUS support pages require manual check due to dynamic content."
    }
}

function Get-LatestMsiBiosInfo {
    param([string]$BoardProduct)
    if ($SkipWebLookup) { return $null }

    # MSI URLs often use the product name directly
    # Example: https://www.msi.com/Motherboard/MAG-B650-TOMAHAWK-WIFI/support#bios
    $slug = $BoardProduct -replace '\s+', '-'
    return [pscustomobject]@{
        SourceUrl     = "https://www.msi.com/search/$($BoardProduct)"
        DirectLink    = "https://www.msi.com/Motherboard/$slug/support#bios"
        LatestVersion = $null # Parsing requires JS/Headless browser
        Note          = "MSI support pages require manual check due to dynamic content."
    }
}

function Get-LatestASRockBiosInfo {
    param(
        [string]$BoardProduct,
        [string]$BoardManufacturer
    )

    if ($BoardManufacturer -notmatch 'ASRock') { return $null }
    if ($SkipWebLookup) { return $null }

    # Quick connectivity check
    if (-not (Test-Connection -ComputerName www.asrock.com -Count 1 -Quiet)) {
        return $null
    }

    try {
        $url = 'https://www.asrock.com/support/index.asp?cat=BIOS'
        $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 20
        $content = $response.Content
        if (-not $content) { return $null }

        $escapedBoard = [regex]::Escape($BoardProduct)
        $pattern = $escapedBoard + '\s*</td>\s*<td[^>]*>\s*([^<]+?)\s*</td>\s*<td[^>]*>\s*([^<]+?)\s*</td>'
        $match = [regex]::Match($content, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

        if ($match.Success) {
            return [pscustomobject]@{
                SourceUrl     = $url
                Board         = $BoardProduct
                LatestVersion = $match.Groups[1].Value.Trim()
                LatestDate    = $match.Groups[2].Value.Trim()
            }
        }

        return $null
    } catch {
        return $null
    }
}

function Get-NvidiaLatestDriverVersion {
    if ($SkipWebLookup) { return $null }

    # Quick connectivity check
    if (-not (Test-Connection -ComputerName www.nvidia.com -Count 1 -Quiet)) {
        return $null
    }

    try {
        $driversPage = Invoke-WebRequest -Uri 'https://www.nvidia.com/en-us/drivers/' -UseBasicParsing -TimeoutSec 20
        $content = $driversPage.Content
        if (-not $content) { return $null }

        $matches = [regex]::Matches($content, '\b(\d{3}\.\d{2})\b')
        if (-not $matches -or $matches.Count -eq 0) { return $null }

        $versions = $matches | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        $latest = $versions | Sort-Object {
            try { [version]$_ } catch { [version]'0.0' }
        } | Select-Object -Last 1

        return [pscustomobject]@{
            LatestVersion = $latest
            SourceUrl     = 'https://www.nvidia.com/en-us/drivers/'
        }
    } catch {
        return $null
    }
}

function Get-AmdDriverInfo {
    return [pscustomobject]@{
        SourceUrl = 'https://www.amd.com/en/support/download/drivers.html'
        ToolUrl   = 'https://www.amd.com/en/resources/support-articles/faqs/GPU-131.html'
        Note      = 'AMD latest driver detection is best handled by AMD Auto-Detect and Install Tool.'
    }
}

function Get-IntelDriverInfo {
    return [pscustomobject]@{
        SourceUrl      = 'https://www.intel.com/content/www/us/en/support/detect.html'
        DownloadCenter = 'https://www.intel.com/content/www/us/en/download-center/home.html'
        Note           = 'Intel latest driver detection is best handled by Intel Driver and Support Assistant.'
    }
}

function Check-BIOS {
    if (-not (Should-RunPhase 'Drivers')) { return }

    Write-Section '[10/20] Checking motherboard firmware online...'

    if ($AuditOnly) {
        Write-Info 'AuditOnly enabled. Would read motherboard/BIOS info and perform web lookup if enabled.'
        Add-SectionResult -Name 'BIOS Check' -Status 'Audit' -Details 'Would compare installed BIOS against parsed vendor data'
        return
    }

    try {
        Write-Host '  Reading motherboard information...' -ForegroundColor Gray
        $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
        $bios = Get-CimInstance -ClassName Win32_BIOS
        $baseBoard = Get-CimInstance -ClassName Win32_BaseBoard

        Write-Host ('  Manufacturer: ' + $computerSystem.Manufacturer) -ForegroundColor Gray
        Write-Host ('  Model: ' + $computerSystem.Model) -ForegroundColor Gray
        Write-Host ('  Motherboard: ' + $baseBoard.Product) -ForegroundColor Gray
        Write-Host ('  BIOS Version: ' + $bios.SMBIOSBIOSVersion) -ForegroundColor Gray
        Write-Host ('  BIOS Date: ' + $bios.ReleaseDate) -ForegroundColor Gray

        if ($SkipWebLookup) {
            Write-Host '  Online BIOS lookup disabled by parameter' -ForegroundColor Gray
            Add-SectionResult -Name 'BIOS Check' -Status 'Skipped' -Details 'Web lookup disabled'
            return
        }

        $latestBios = $null
        if ($baseBoard.Manufacturer -match 'ASRock') {
            $latestBios = Get-LatestASRockBiosInfo -BoardProduct $baseBoard.Product -BoardManufacturer $baseBoard.Manufacturer
        } elseif ($baseBoard.Manufacturer -match 'ASUSTeK|ASUS') {
            $latestBios = Get-LatestAsusBiosInfo -BoardProduct $baseBoard.Product
        } elseif ($baseBoard.Manufacturer -match 'Micro-Star|MSI') {
            $latestBios = Get-LatestMsiBiosInfo -BoardProduct $baseBoard.Product
        }

        if ($latestBios) {
            if ($latestBios.LatestVersion) {
                Write-Host ('  Latest online BIOS version: ' + $latestBios.LatestVersion) -ForegroundColor Gray
                if ($latestBios.LatestDate) { Write-Host ('  Latest online BIOS date: ' + $latestBios.LatestDate) -ForegroundColor Gray }
            }
            $displayLink = if ($latestBios.DirectLink) { $latestBios.DirectLink } else { $latestBios.SourceUrl }
            Write-Host ('  Support Link: ' + $displayLink) -ForegroundColor Gray

            $cmp = if ($latestBios.LatestVersion) { Compare-VersionStrings -A $bios.SMBIOSBIOSVersion -B $latestBios.LatestVersion } else { $null }

            if ($cmp -lt 0) {
                Write-Warn ('BIOS update available: installed ' + $bios.SMBIOSBIOSVersion + ', latest ' + $latestBios.LatestVersion)
                Add-SectionResult -Name 'BIOS Check' -Status 'Partial' -Details 'BIOS update appears available'
            } elseif ($cmp -eq 0) {
                Write-Ok 'BIOS is up to date'
                Add-SectionResult -Name 'BIOS Check' -Status 'Success' -Details 'Installed BIOS matches parsed latest version'
            } elseif ($cmp -gt 0) {
                Write-Ok 'Installed BIOS appears newer than parsed support-table value'
                Add-SectionResult -Name 'BIOS Check' -Status 'Success' -Details 'Installed BIOS appears newer than parsed website result'
            } else {
                Write-ExpectedWarn "Automated version comparison not supported for $($baseBoard.Manufacturer)."
                if ($latestBios.Note) { Write-Host ("  Note: " + $latestBios.Note) -ForegroundColor Gray }
                Add-SectionResult -Name 'BIOS Check' -Status 'ExpectedLimit' -Details 'Manual check required (dynamic vendor site)'
            }
        } else {
            Write-ExpectedWarn 'Online BIOS lookup unavailable. This is often expected because vendor support pages change layout or block automation.'
            Add-SectionResult -Name 'BIOS Check' -Status 'ExpectedLimit' -Details 'Vendor page unavailable or unparseable'
        }
    } catch {
        Write-Err ('Failed to get motherboard information: ' + $_)
        Add-SectionResult -Name 'BIOS Check' -Status 'Failed' -Details $_.ToString()
    }
}

function Check-GPUDrivers {
    if (-not (Should-RunPhase 'Drivers')) { return }

    Write-Section '[11/20] Checking graphics driver versions online...'

    if ($AuditOnly) {
        Write-Info 'AuditOnly enabled. Would inspect local GPU and compare to online data if supported.'
        Add-SectionResult -Name 'GPU Driver Check' -Status 'Audit' -Details 'Would inspect GPU and perform driver lookup'
        return
    }

    try {
        Write-Host '  Detecting graphics hardware...' -ForegroundColor Gray
        $gpus = Get-CimInstance -ClassName Win32_VideoController
        $physicalGpu = $null

        foreach ($gpu in $gpus) {
            if ($gpu.Name -notmatch 'Virtual|Remote|Basic Display|Microsoft Hyper-V|Miracast|Indirect') {
                $physicalGpu = $gpu
                break
            }
        }

        if (-not $physicalGpu) {
            Write-Warn 'No physical GPU detected'
            Add-SectionResult -Name 'GPU Driver Check' -Status 'Skipped' -Details 'No physical GPU detected'
            return
        }

        Write-Host ('  Graphics Card: ' + $physicalGpu.Name) -ForegroundColor Gray
        Write-Host ('  Driver Version (Windows): ' + $physicalGpu.DriverVersion) -ForegroundColor Gray
        Write-Host ('  Driver Date: ' + $physicalGpu.DriverDate) -ForegroundColor Gray

        if ($physicalGpu.Name -match 'NVIDIA|GeForce|Quadro|RTX|GTX') {
            $installedNvidiaVersion = Get-NvidiaDisplayVersionFromWindowsVersion -DriverVersion $physicalGpu.DriverVersion
            if ($installedNvidiaVersion) {
                Write-Host ('  Interpreted NVIDIA driver version: ' + $installedNvidiaVersion) -ForegroundColor Gray
            }

            if ($SkipWebLookup) {
                Write-Host '  Online NVIDIA lookup disabled by parameter' -ForegroundColor Gray
                Add-SectionResult -Name 'GPU Driver Check' -Status 'Skipped' -Details 'Web lookup disabled'
                return
            }

            $nvidiaLatest = Get-NvidiaLatestDriverVersion
            if ($nvidiaLatest -and $nvidiaLatest.LatestVersion) {
                Write-Host ('  Latest NVIDIA version found online: ' + $nvidiaLatest.LatestVersion) -ForegroundColor Gray
                Write-Host ('  Source: ' + $nvidiaLatest.SourceUrl) -ForegroundColor Gray
                if ($installedNvidiaVersion) {
                    $cmp = Compare-VersionStrings -A $installedNvidiaVersion -B $nvidiaLatest.LatestVersion
                    if ($cmp -lt 0) {
                        Write-Warn ('NVIDIA driver update available: installed ' + $installedNvidiaVersion + ', latest ' + $nvidiaLatest.LatestVersion)
                        Add-SectionResult -Name 'GPU Driver Check' -Status 'Partial' -Details 'NVIDIA driver update appears available'
                    } elseif ($cmp -eq 0) {
                        Write-Ok 'NVIDIA driver appears up to date'
                        Add-SectionResult -Name 'GPU Driver Check' -Status 'Success' -Details 'NVIDIA driver appears current'
                    } else {
                        Write-Ok 'Installed NVIDIA driver appears newer than parsed website version'
                        Add-SectionResult -Name 'GPU Driver Check' -Status 'Success' -Details 'Installed NVIDIA driver appears newer than parsed website value'
                    }
                } else {
                    Add-SectionResult -Name 'GPU Driver Check' -Status 'Success' -Details 'NVIDIA latest version found; local driver mapping unavailable'
                }
            } else {
                Write-ExpectedWarn 'Automatic NVIDIA latest-driver lookup failed. This is often expected because NVIDIA pages can be dynamic or bot-protected.'
                Write-Host '  Use NVIDIA App or GeForce Experience for authoritative driver checks.' -ForegroundColor Gray
                Add-SectionResult -Name 'GPU Driver Check' -Status 'ExpectedLimit' -Details 'NVIDIA site unavailable or unparseable'
            }
        } elseif ($physicalGpu.Name -match 'AMD|Radeon|RX') {
            $amdInfo = Get-AmdDriverInfo
            Write-Warn $amdInfo.Note
            Write-Host ('  AMD Drivers and Support: ' + $amdInfo.SourceUrl) -ForegroundColor Gray
            Write-Host ('  AMD Auto-Detect Tool: ' + $amdInfo.ToolUrl) -ForegroundColor Gray
            Add-SectionResult -Name 'GPU Driver Check' -Status 'ExpectedLimit' -Details 'AMD automatic latest version lookup delegated to vendor tool'
        } elseif ($physicalGpu.Name -match 'Intel|Intel\(R\)|Arc') {
            $intelInfo = Get-IntelDriverInfo
            Write-Warn $intelInfo.Note
            Write-Host ('  Intel Driver and Support Assistant: ' + $intelInfo.SourceUrl) -ForegroundColor Gray
            Write-Host ('  Intel Download Center: ' + $intelInfo.DownloadCenter) -ForegroundColor Gray
            Add-SectionResult -Name 'GPU Driver Check' -Status 'ExpectedLimit' -Details 'Intel automatic latest version lookup delegated to vendor tool'
        } else {
            Write-Warn 'GPU manufacturer not automatically detected.'
            Add-SectionResult -Name 'GPU Driver Check' -Status 'ExpectedLimit' -Details 'GPU vendor could not be classified'
        }
    } catch {
        Write-Err ('Failed to get graphics card information: ' + $_)
        Add-SectionResult -Name 'GPU Driver Check' -Status 'Failed' -Details $_.ToString()
    }
}

function Update-MicrosoftStoreApps {
    if (-not (Should-RunPhase 'Core')) { return }

    Write-Section '[12/20] Checking Microsoft Store source and app coverage...'

    if ($AuditOnly) {
        Write-Info 'AuditOnly enabled. Would list winget sources.'
        Add-SectionResult -Name 'Microsoft Store Coverage' -Status 'Audit' -Details 'Would list winget sources'
        return
    }

    $commandPresent = $false
    if (Get-Command 'winget' -ErrorAction SilentlyContinue) {
        $commandPresent = $true
        try {
            Write-Host '  Listing winget sources...' -ForegroundColor Gray
            winget source list
            Write-Ok 'winget source list completed'
            Add-SectionResult -Name 'Microsoft Store Coverage' -Status 'Success' -Details 'winget source list completed'
        } catch {
            Write-Err ('winget source list failed: ' + $_)
            Add-SectionResult -Name 'Microsoft Store Coverage' -Status 'Failed' -Details $_.ToString()
        }
    } else {
        Write-Host '  winget not found (skipped)' -ForegroundColor Gray
    }

    if (-not $commandPresent) {
        Add-SectionResult -Name 'Microsoft Store Coverage' -Status 'Skipped' -Details 'winget not installed'
    }
}

function Report-SystemState {
    if (-not (Should-RunPhase 'Core')) { return }

    Write-Section '[18/20] Reporting current system state...'
    try {
        $pending = Test-PendingReboot
        Write-Host ('  Pending reboot right now: ' + $pending.IsPending) -ForegroundColor Gray
        if ($pending.IsPending -and $pending.Reasons) {
            Write-Host ('  Reboot reasons: ' + ($pending.Reasons -join ', ')) -ForegroundColor Gray
        }

        $py = Get-CommandVersion -CommandName 'python' -VersionScript { python --version 2>&1 }
        $wg = Get-CommandVersion -CommandName 'winget' -VersionScript { winget --version 2>$null }

        if ($py) { Write-Host ('  Python: ' + $py) -ForegroundColor Gray }
        if ($wg) { Write-Host ('  winget: ' + $wg) -ForegroundColor Gray }

        if ($script:Capabilities['dotnet']) {
            if (Test-DotNetSdkInstalled) {
                $sdks = & dotnet --list-sdks 2>$null
                if ($sdks) {
                    Write-Host ('  .NET SDKs: ' + (($sdks | Select-Object -First 3) -join '; ')) -ForegroundColor Gray
                }
            } else {
                Write-Host '  .NET SDKs: none detected (runtime-only or host-only install)' -ForegroundColor Gray
            }
        }

        Add-SectionResult -Name 'System State' -Status 'Success' -Details 'Current reboot state and key tool versions reported'
    } catch {
        Write-Warn ('System state reporting encountered an issue: ' + $_)
        Add-SectionResult -Name 'System State' -Status 'Partial' -Details $_.ToString()
    }
}

function Update-WSLDistros {
    if (-not (Should-RunPhase 'Packages') -or $SkipWSL) { return }

    Write-Section '[13/20] Updating WSL components...'
    if ($AuditOnly) {
        Write-Info 'AuditOnly enabled. Would update WSL components.'
        Add-SectionResult -Name 'WSL Components' -Status 'Audit' -Details 'Would update WSL'
        return
    }

    $commandPresent = $false
    $actions = New-Object System.Collections.Generic.List[object]

    $commandPresent = Invoke-IfCommandExists -CommandName 'wsl' -MissingMessage 'wsl not found (skipped)' -Action {
        try {
            Write-Host '  Updating WSL components...' -ForegroundColor Gray
            & wsl --update 2>$null
            $actions.Add([pscustomobject]@{ Name='WSL update'; Success=($LASTEXITCODE -eq 0); ExitCode=$LASTEXITCODE }) | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-Ok 'WSL components updated' }
            else { Write-Err ('WSL update failed (exit code ' + $LASTEXITCODE + ')') }
        } catch {
            Write-Err ('WSL update failed: ' + $_)
            $actions.Add([pscustomobject]@{ Name='WSL'; Success=$false; ExitCode=$null }) | Out-Null
        }
    }

    if (-not $commandPresent) {
        Add-SectionResult -Name 'WSL Components' -Status 'Skipped' -Details 'wsl not installed'
        return
    }

    $total = $actions.Count
    $successes = @($actions | Where-Object { $_.Success }).Count

    if ($total -eq 0) {
        Add-SectionResult -Name 'WSL Components' -Status 'Skipped' -Details 'No WSL actions performed'
    } elseif ($successes -eq $total) {
        Add-SectionResult -Name 'WSL Components' -Status 'Success' -Details 'WSL components updated successfully'
    } else {
        Add-SectionResult -Name 'WSL Components' -Status 'Failed' -Details 'WSL update failed'
    }
}

function Update-DefenderSignatures {
    if (-not (Should-RunPhase 'Core') -or $SkipDefender) { return }

    Write-Section '[14/20] Updating Windows Defender signatures...'
    if ($AuditOnly) {
        Write-Info 'AuditOnly enabled. Would update Windows Defender signatures.'
        Add-SectionResult -Name 'Defender Signatures' -Status 'Audit' -Details 'Would update Windows Defender definitions'
        return
    }

    try {
        if (-not (Test-IsAdmin)) {
            Write-Warn 'Not running as administrator. Windows Defender signature update skipped.'
            Write-Host '  To enable this section, run the script as Administrator.' -ForegroundColor Gray
            Add-SectionResult -Name 'Defender Signatures' -Status 'Skipped' -Details 'Administrator privileges required'
            return
        }

        Write-Host '  Updating Windows Defender signatures...' -ForegroundColor Gray
        & "$env:ProgramFiles\Windows Defender\MpCmdRun.exe" -SignatureUpdate 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Ok 'Windows Defender signatures updated'
            Add-SectionResult -Name 'Defender Signatures' -Status 'Success' -Details 'Signatures updated successfully'
        } elseif ($LASTEXITCODE -eq 2) {
            Write-Warn 'Windows Defender signature update encountered a network error (exit code 2)'
            Write-Host '  This is often a transient issue with Windows Update servers.' -ForegroundColor Gray
            Write-Host '  Signatures may still be reasonably current.' -ForegroundColor Gray
            Add-SectionResult -Name 'Defender Signatures' -Status 'ExpectedLimit' -Details 'Network error with Windows Update servers (exit code 2)'
        } else {
            Write-Err ('Windows Defender signature update failed (exit code ' + $LASTEXITCODE + ')')
            Add-SectionResult -Name 'Defender Signatures' -Status 'Failed' -Details ('Exit code: ' + $LASTEXITCODE)
        }
    } catch {
        Write-Err ('Windows Defender signature update failed: ' + $_)
        Add-SectionResult -Name 'Defender Signatures' -Status 'Failed' -Details $_.ToString()
    }
}

function Update-OllamaModels {
    if (-not (Should-RunPhase 'Tools') -or $SkipOllama) { return }

    Write-Section '[17/20] Updating Ollama models...'
    if ($AuditOnly) {
        Write-Info 'AuditOnly enabled. Would update Ollama models.'
        Add-SectionResult -Name 'Ollama Models' -Status 'Audit' -Details 'Would update Ollama models'
        return
    }

    $commandPresent = $false
    $actions = New-Object System.Collections.Generic.List[object]

    $commandPresent = Invoke-IfCommandExists -CommandName 'ollama' -MissingMessage 'ollama not found (skipped)' -Action {
        try {
            Write-Host '  Checking for installed Ollama models...' -ForegroundColor Gray
            Write-Host '  This may take a moment if models are large...' -ForegroundColor Gray
            $models = & ollama list 2>$null
            if ($LASTEXITCODE -eq 0 -and $models) {
                $modelList = @($models | Select-Object -Skip 1 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                if ($modelList.Count -gt 0) {
                    Write-Host "  Found $($modelList.Count) Ollama model(s)" -ForegroundColor Cyan
                    foreach ($modelLine in $modelList) {
                        $modelName = ($modelLine -split '\s+')[0]
                        if (-not [string]::IsNullOrWhiteSpace($modelName)) {
                            Write-Host "    Pulling latest for $modelName..." -ForegroundColor Gray
                            Write-Host "    Downloading model updates..." -ForegroundColor Gray
                            & ollama pull $modelName 2>$null
                            $actions.Add([pscustomobject]@{ Name=$modelName; Success=($LASTEXITCODE -eq 0); ExitCode=$LASTEXITCODE }) | Out-Null
                            if ($LASTEXITCODE -eq 0) { Write-Ok "Ollama model '$modelName' updated" }
                            else { Write-Err ("Ollama model '$modelName' update failed (exit code " + $LASTEXITCODE + ")") }
                        }
                    }
                } else {
                    Write-Host '  No Ollama models found' -ForegroundColor Green
                }
            } else {
                Write-Host '  No Ollama models found' -ForegroundColor Gray
            }
        } catch {
            Write-Err ('Ollama model update failed: ' + $_)
            $actions.Add([pscustomobject]@{ Name='Ollama'; Success=$false; ExitCode=$null }) | Out-Null
        }
    }

    if (-not $commandPresent) {
        Add-SectionResult -Name 'Ollama Models' -Status 'Skipped' -Details 'ollama not installed'
        return
    }

    $total = $actions.Count
    $successes = @($actions | Where-Object { $_.Success }).Count

    if ($total -eq 0) {
        Add-SectionResult -Name 'Ollama Models' -Status 'Skipped' -Details 'No Ollama models found'
    } elseif ($successes -eq $total) {
        Add-SectionResult -Name 'Ollama Models' -Status 'Success' -Details ($successes.ToString() + '/' + $total + ' models updated')
    } elseif ($successes -gt 0) {
        Add-SectionResult -Name 'Ollama Models' -Status 'Partial' -Details ($successes.ToString() + '/' + $total + ' models updated')
    } else {
        Add-SectionResult -Name 'Ollama Models' -Status 'Failed' -Details ('0/' + $total + ' models updated')
    }
}

function Update-Apt {
    if (-not (Should-RunPhase 'Packages') -or $SkipApt) { return }

    Write-Section '[15/20] Updating apt packages (WSL)...'
    if ($AuditOnly) {
        Write-Info 'AuditOnly enabled. Would update apt packages in WSL.'
        Add-SectionResult -Name 'Apt Packages' -Status 'Audit' -Details 'Would update apt packages'
        return
    }

    $commandPresent = $false
    $actions = New-Object System.Collections.Generic.List[object]

    $commandPresent = Invoke-IfCommandExists -CommandName 'wsl' -MissingMessage 'wsl not found (skipped)' -Action {
        try {
            Write-Host '  Checking for apt in WSL...' -ForegroundColor Gray
            Write-Host '  Scanning WSL distributions...' -ForegroundColor Gray
            $distros = & wsl --list 2>$null
            $aptFound = $false
            if ($LASTEXITCODE -eq 0 -and $distros) {
                $distroList = @($distros | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { ($_ -split '\s+')[0].Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                foreach ($distro in $distroList) {
                    & wsl --distribution $distro -- which apt 2>$null | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        $aptFound = $true
                        Write-Host "  apt found in WSL distro '$distro', updating packages..." -ForegroundColor Cyan
                        Write-Host '    Running apt update...' -ForegroundColor Gray
                        & wsl --distribution $distro -- bash -c "sudo apt update" 2>$null
                        $updateSuccess = ($LASTEXITCODE -eq 0)
                        $actions.Add([pscustomobject]@{ Name='apt update'; Success=$updateSuccess; ExitCode=$LASTEXITCODE }) | Out-Null

                        if ($updateSuccess) {
                            Write-Host '    Running apt upgrade...' -ForegroundColor Gray
                            & wsl --distribution $distro -- bash -c "sudo apt upgrade -y" 2>$null
                            $upgradeSuccess = ($LASTEXITCODE -eq 0)
                            $actions.Add([pscustomobject]@{ Name='apt upgrade'; Success=$upgradeSuccess; ExitCode=$LASTEXITCODE }) | Out-Null

                            if ($upgradeSuccess) {
                                Write-Ok 'apt packages updated'
                            } else {
                                Write-Err ('apt upgrade failed (exit code ' + $LASTEXITCODE + ')')
                            }
                        } else {
                            Write-Err ('apt update failed (exit code ' + $LASTEXITCODE + ')')
                        }
                        break
                    }
                }
            }
            if (-not $aptFound) {
                Write-Host '  apt not found in any WSL distro (skipped)' -ForegroundColor Gray
                Write-Host '  Note: Some WSL distros like docker-desktop do not include apt' -ForegroundColor Gray
            }
        } catch {
            Write-Err ('apt update failed: ' + $_)
            $actions.Add([pscustomobject]@{ Name='apt'; Success=$false; ExitCode=$null }) | Out-Null
        }
    }

    if (-not $commandPresent) {
        Add-SectionResult -Name 'Apt Packages' -Status 'Skipped' -Details 'wsl not installed or apt not available'
        return
    }

    $total = $actions.Count
    $successes = @($actions | Where-Object { $_.Success }).Count

    if ($total -eq 0) {
        Add-SectionResult -Name 'Apt Packages' -Status 'Skipped' -Details 'apt not available in WSL'
    } elseif ($successes -eq $total) {
        Add-SectionResult -Name 'Apt Packages' -Status 'Success' -Details ($successes.ToString() + '/' + $total + ' apt operations succeeded')
    } elseif ($successes -gt 0) {
        Add-SectionResult -Name 'Apt Packages' -Status 'Partial' -Details ($successes.ToString() + '/' + $total + ' apt operations succeeded')
    } else {
        Add-SectionResult -Name 'Apt Packages' -Status 'Failed' -Details ('0/' + $total + ' apt operations succeeded')
    }
}

function Update-PowerShellHelp {
    if (-not (Should-RunPhase 'Tools') -or $SkipPowerShellHelp) { return }

    Write-Section '[16/20] Updating PowerShell help...'
    if ($AuditOnly) {
        Write-Info 'AuditOnly enabled. Would update PowerShell help.'
        Add-SectionResult -Name 'PowerShell Help' -Status 'Audit' -Details 'Would update PowerShell help files'
        return
    }

    try {
        Write-Host '  Updating PowerShell help...' -ForegroundColor Gray
        Write-Host '  Downloading help files...' -ForegroundColor Gray
        Update-Help -Force -ErrorAction SilentlyContinue | Out-Null
        Write-Ok 'PowerShell help updated'
        Add-SectionResult -Name 'PowerShell Help' -Status 'Success' -Details 'Help files updated'
    } catch {
        Write-Err ('PowerShell help update failed: ' + $_)
        Add-SectionResult -Name 'PowerShell Help' -Status 'Partial' -Details $_.ToString()
    }
}

function Finish-Up {
    Write-Section '[19/20] Final summary...'

    $script:Context.PendingRebootAtEnd = (Test-PendingReboot).IsPending
    $duration = New-TimeSpan -Start $script:StartTime -End (Get-Date)

    Write-Host ('  Log file: ' + $script:LogFile) -ForegroundColor Gray
    Write-Host ('  Run duration: ' + [int]$duration.TotalMinutes + ' min ' + $duration.Seconds + ' sec') -ForegroundColor Gray
    Write-Host ('  Pending reboot at start: ' + $script:Context.PendingRebootAtStart) -ForegroundColor Gray
    Write-Host ('  Pending reboot at end: ' + $script:Context.PendingRebootAtEnd) -ForegroundColor Gray

    Write-BlankLine

    $statusOrder = @('Failed','Partial','ExpectedLimit','Skipped','Audit','Success')
    foreach ($status in $statusOrder) {
        $items = @($script:SectionResults | Where-Object { $_.Status -eq $status })
        if ($items.Count -gt 0) {
            Write-Host ('  ' + $status + ': ' + $items.Count) -ForegroundColor Gray
            foreach ($item in $items) {
                Write-Host ('    - ' + $item.Name + ' :: ' + $item.Details) -ForegroundColor DarkGray
            }
        }
    }

    Write-BlankLine
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host ('Update Script v' + $script:ScriptVersion + ' Completed') -ForegroundColor Cyan
    Write-Host '========================================' -ForegroundColor Cyan

    try {
        Stop-Transcript | Out-Null
    } catch {}
}

function Show-UsageHints {
    Write-Section '[20/20] Usage hints...'
    Write-Host '  Examples:' -ForegroundColor Gray
    Write-Host '    .\update.ps1' -ForegroundColor DarkGray
    Write-Host '    .\update.ps1 -Mode Fast' -ForegroundColor DarkGray
    Write-Host '    .\update.ps1 -Mode Full -PromptForRiskyActions' -ForegroundColor DarkGray
    Write-Host '    .\update.ps1 -AuditOnly' -ForegroundColor DarkGray
    Write-Host '    .\update.ps1 -Mode Drivers -SkipSteam' -ForegroundColor DarkGray
}

Start-Sleep -Seconds 1
Write-Host '========================================' -ForegroundColor Cyan
Write-Host ('Starting System Update Script v' + $script:ScriptVersion) -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan

Initialize-Capabilities
Export-InventorySnapshots
Update-WingetPackages
Update-PythonPackages
Update-WindowsAndDrivers
Update-CommonPackageManagers
Update-DotNetAndRust
Update-AdditionalPythonTools
Update-Steam
Update-VendorUtilities
Check-BIOS
Check-GPUDrivers
Update-MicrosoftStoreApps
Update-WSLDistros
Update-DefenderSignatures
Update-Apt
Update-PowerShellHelp
Update-OllamaModels
Report-SystemState
Finish-Up
Show-UsageHints

Write-BlankLine
Write-Host 'Press any key to exit...' -ForegroundColor Cyan
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')