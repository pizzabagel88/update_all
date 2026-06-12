# System Update Script v2
# Personal aggressive updater with broader ecosystem detection and logging

$ErrorActionPreference = 'Continue'
$script:LogRoot = Join-Path $env:USERPROFILE 'Desktop\Updater\logs'
if (-not (Test-Path $script:LogRoot)) {
    New-Item -ItemType Directory -Path $script:LogRoot -Force | Out-Null
}
$script:LogFile = Join-Path $script:LogRoot ('update-log-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
try {
    Start-Transcript -Path $script:LogFile -Force | Out-Null
} catch {}

function Write-Section {
    param([string]$Text)
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

function Write-Err {
    param([string]$Text)
    Write-Host ('[ERR] ' + $Text) -ForegroundColor Red
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
        if ($AllowNonZero -or $LASTEXITCODE -eq 0) {
            if ($SuccessMessage) { Write-Ok $SuccessMessage }
            return $true
        }
        Write-Err ($FailurePrefix + ' (exit code ' + $LASTEXITCODE + ')')
        return $false
    } catch {
        Write-Err ($FailurePrefix + ' ' + $_)
        return $false
    }
}

function Invoke-IfCommandExists {
    param(
        [string]$CommandName,
        [scriptblock]$Action,
        [string]$MissingMessage
    )

    if (Get-Command $CommandName -ErrorAction SilentlyContinue) {
        & $Action
    } else {
        if ($MissingMessage) {
            Write-Host ('  ' + $MissingMessage) -ForegroundColor Gray
        }
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

function Get-LatestASRockBiosInfo {
    param(
        [string]$BoardProduct,
        [string]$BoardManufacturer
    )

    if ($BoardManufacturer -notmatch 'ASRock') { return $null }

    try {
        $url = 'https://www.asrock.com/support/index.asp?cat=BIOS'
        $response = Invoke-WebRequest -Uri $url -UseBasicParsing
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
    try {
        $driversPage = Invoke-WebRequest -Uri 'https://www.nvidia.com/en-us/drivers/' -UseBasicParsing
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

function Update-WingetPackages {
    Write-Section '[1/12] Updating WinGet sources and packages...'
    Invoke-IfCommandExists -CommandName 'winget' -MissingMessage 'winget not found (skipped)' -Action {
        Invoke-ExternalCommand -FilePath 'winget' -Arguments @('source','update') -SuccessMessage 'winget sources updated' -FailurePrefix 'winget source update failed:' | Out-Null
        Invoke-ExternalCommand -FilePath 'winget' -Arguments @('upgrade','Microsoft.AppInstaller','--accept-source-agreements','--accept-package-agreements') -SuccessMessage 'winget/App Installer update attempted' -FailurePrefix 'winget self-update failed:' -AllowNonZero | Out-Null
        Invoke-ExternalCommand -FilePath 'winget' -Arguments @('upgrade','--all','--include-unknown','--accept-source-agreements','--accept-package-agreements') -SuccessMessage 'winget package updates completed' -FailurePrefix 'winget package update failed:' | Out-Null
    }
    Write-Host ''
}

function Update-PythonPackages {
    Write-Section '[2/12] Updating pip and Python packages...'
    Invoke-IfCommandExists -CommandName 'python' -MissingMessage 'python not found (skipped)' -Action {
        Invoke-ExternalCommand -FilePath 'python' -Arguments @('-m','pip','install','--upgrade','pip') -SuccessMessage 'pip updated' -FailurePrefix 'pip update failed:' | Out-Null
        try {
            $json = python -m pip list --outdated --format=json 2>$null
            if ($LASTEXITCODE -eq 0 -and $json) {
                $outdatedPackages = $json | ConvertFrom-Json
                if ($outdatedPackages -and $outdatedPackages.Count -gt 0) {
                    foreach ($pkg in $outdatedPackages) {
                        Write-Host ('  Updating ' + $pkg.name + ' (' + $pkg.version + ' -> ' + $pkg.latest_version + ')...') -ForegroundColor Gray
                        & python -m pip install --upgrade $pkg.name
                        if ($LASTEXITCODE -ne 0) {
                            Write-Err ('Failed to update Python package ' + $pkg.name + ' (exit code ' + $LASTEXITCODE + ')')
                        }
                    }
                    Write-Ok 'Python packages update pass completed'
                } else {
                    Write-Ok 'No outdated Python packages found'
                }
            } else {
                Write-Err 'Failed to check for outdated Python packages'
            }
        } catch {
            Write-Err ('Python package update failed: ' + $_)
        }
    }
    Write-Host ''
}

function Update-WindowsAndDrivers {
    Write-Section '[3/12] Updating Windows, Microsoft Update, and drivers...'
    try {
        if (-not (Test-IsAdmin)) {
            Write-Warn 'Not running as administrator. Windows Update and driver updates skipped.'
            Write-Host '  To enable this section, run the script as Administrator.' -ForegroundColor Gray
            Write-Host ''
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
            Get-WindowsUpdate -MicrosoftUpdate -AcceptAll -Install -AutoReboot

            try {
                Write-Host '  Running driver-focused Windows Update pass...' -ForegroundColor Gray
                Get-WindowsUpdate -MicrosoftUpdate -Category Drivers -AcceptAll -Install -AutoReboot
            } catch {
                Write-Warn 'Driver-focused Windows Update pass failed or no driver updates were available'
            }

            Write-Ok 'Windows Update pass completed'
        } else {
            Write-Warn 'PSWindowsUpdate installation failed. Skipping Windows Update.'
        }
    } catch {
        Write-Err ('Windows Update failed: ' + $_)
    }
    Write-Host ''
}

function Update-CommonPackageManagers {
    Write-Section '[4/12] Updating Chocolatey, Scoop, npm, pnpm, and Yarn...'

    Invoke-IfCommandExists -CommandName 'choco' -MissingMessage 'Chocolatey not found (skipped)' -Action {
        Write-Host '  Chocolatey found. Updating packages...' -ForegroundColor Gray
        & choco upgrade all -y
        if ($LASTEXITCODE -eq 0) { Write-Ok 'Chocolatey packages updated' } else { Write-Err ('Chocolatey update failed (exit code ' + $LASTEXITCODE + ')') }
    }

    Invoke-IfCommandExists -CommandName 'scoop' -MissingMessage 'Scoop not found (skipped)' -Action {
        Write-Host '  Scoop found. Updating packages...' -ForegroundColor Gray
        & scoop update '*'
        if ($LASTEXITCODE -eq 0) { Write-Ok 'Scoop packages updated' } else { Write-Err ('Scoop update failed (exit code ' + $LASTEXITCODE + ')') }
    }

    Invoke-IfCommandExists -CommandName 'npm' -MissingMessage 'npm not found (skipped)' -Action {
        Write-Host '  npm found. Updating global packages...' -ForegroundColor Gray
        & npm update -g
        if ($LASTEXITCODE -eq 0) { Write-Ok 'npm global packages updated' } else { Write-Err ('npm update failed (exit code ' + $LASTEXITCODE + ')') }
    }

    Invoke-IfCommandExists -CommandName 'pnpm' -MissingMessage 'pnpm not found (skipped)' -Action {
        Write-Host '  pnpm found. Updating global packages...' -ForegroundColor Gray
        & pnpm update -g
        if ($LASTEXITCODE -eq 0) { Write-Ok 'pnpm global packages updated' } else { Write-Err ('pnpm update failed (exit code ' + $LASTEXITCODE + ')') }
    }

    Invoke-IfCommandExists -CommandName 'yarn' -MissingMessage 'Yarn not found (skipped)' -Action {
        Write-Host '  Yarn found. Updating global packages...' -ForegroundColor Gray
        & yarn global upgrade
        if ($LASTEXITCODE -eq 0) { Write-Ok 'Yarn global packages updated' } else { Write-Err ('Yarn update failed (exit code ' + $LASTEXITCODE + ')') }
    }

    Write-Host ''
}

function Update-DotNetAndRust {
    Write-Section '[5/12] Updating .NET and Rust tooling...'

    Invoke-IfCommandExists -CommandName 'dotnet' -MissingMessage '.NET SDK not found (skipped)' -Action {
        Write-Host '  dotnet found. Updating global tools...' -ForegroundColor Gray
        & dotnet tool update --all --global
        if ($LASTEXITCODE -eq 0) {
            Write-Ok '.NET global tools updated'
        } else {
            Write-Warn '.NET built-in global tool update failed, trying dotnet-update-all-tools if available'
            if (Get-Command 'dotnet-update-all-tools' -ErrorAction SilentlyContinue) {
                & dotnet-update-all-tools
                if ($LASTEXITCODE -eq 0) { Write-Ok 'dotnet-update-all-tools completed' } else { Write-Err ('dotnet-update-all-tools failed (exit code ' + $LASTEXITCODE + ')') }
            } else {
                Write-Host '  dotnet-update-all-tools not found (skipped)' -ForegroundColor Gray
            }
        }
    }

    Invoke-IfCommandExists -CommandName 'cargo' -MissingMessage 'cargo not found (skipped)' -Action {
        Write-Host '  cargo found. Checking for cargo-install-update...' -ForegroundColor Gray
        if (Get-Command 'cargo-install-update' -ErrorAction SilentlyContinue) {
            & cargo-install-update -a
            if ($LASTEXITCODE -eq 0) { Write-Ok 'Rust cargo-installed binaries updated' } else { Write-Err ('cargo-install-update failed (exit code ' + $LASTEXITCODE + ')') }
        } else {
            Write-Host '  cargo-install-update not found. Installing helper...' -ForegroundColor Gray
            & cargo install cargo-update
            if ($LASTEXITCODE -eq 0 -and (Get-Command 'cargo-install-update' -ErrorAction SilentlyContinue)) {
                & cargo-install-update -a
                if ($LASTEXITCODE -eq 0) { Write-Ok 'Rust cargo-installed binaries updated' } else { Write-Err ('cargo-install-update failed (exit code ' + $LASTEXITCODE + ')') }
            } else {
                Write-Warn 'Could not install cargo-update helper'
            }
        }
    }

    Write-Host ''
}

function Update-AdditionalPythonTools {
    Write-Section '[6/12] Updating Poetry and uv if present...'

    Invoke-IfCommandExists -CommandName 'poetry' -MissingMessage 'Poetry not found (skipped)' -Action {
        Write-Host '  Poetry found. Self-updating...' -ForegroundColor Gray
        & poetry self update
        if ($LASTEXITCODE -eq 0) { Write-Ok 'Poetry updated' } else { Write-Err ('Poetry update failed (exit code ' + $LASTEXITCODE + ')') }
    }

    Invoke-IfCommandExists -CommandName 'uv' -MissingMessage 'uv not found (skipped)' -Action {
        Write-Host '  uv found. Self-updating...' -ForegroundColor Gray
        & uv self update
        if ($LASTEXITCODE -eq 0) { Write-Ok 'uv updated' } else { Write-Err ('uv update failed (exit code ' + $LASTEXITCODE + ')') }
    }

    Write-Host ''
}

function Update-Steam {
    Write-Section '[7/12] Checking Steam...'
    try {
        $steamPaths = @()
        if ($env:ProgramFiles) { $steamPaths += (Join-Path $env:ProgramFiles 'Steam\steam.exe') }
        if (${env:ProgramFiles(x86)}) { $steamPaths += (Join-Path ${env:ProgramFiles(x86)} 'Steam\steam.exe') }
        $steamPath = $steamPaths | Where-Object { Test-Path $_ } | Select-Object -First 1

        if ($steamPath) {
            Write-Host '  Steam found. Starting Steam to check for updates...' -ForegroundColor Gray
            Start-Process -FilePath $steamPath -ArgumentList '-silent' -NoNewWindow
            Write-Ok 'Steam launched for background update checks'
        } else {
            Write-Host '  Steam not found (skipped)' -ForegroundColor Gray
        }
    } catch {
        Write-Err ('Steam update failed: ' + $_)
    }
    Write-Host ''
}

function Update-VendorUtilities {
    Write-Section '[8/12] Launching vendor update utilities if installed...'

    $candidates = @(
        @{ Name='Dell Command Update'; Paths=@('C:\Program Files\Dell\CommandUpdate\dcu-cli.exe'); Args=@('/applyUpdates','-silent') },
        @{ Name='Lenovo System Update'; Paths=@('C:\Program Files (x86)\Lenovo\System Update\tvsu.exe'); Args=@('/CM','-search','A','-action','INSTALL','-includerebootpackages','1') },
        @{ Name='MyASUS'; Paths=@('C:\Program Files (x86)\ASUS\MyASUS\MyASUS.exe'); Args=@() },
        @{ Name='MSI Center'; Paths=@('C:\Program Files (x86)\MSI\One Dragon Center\OneDragonCenter.exe','C:\Program Files\MSI\MSI Center\MSI.CentralServer.exe'); Args=@() },
        @{ Name='Gigabyte Control Center'; Paths=@('C:\Program Files\GIGABYTE\Control Center\GCC.exe'); Args=@() },
        @{ Name='Samsung Magician'; Paths=@('C:\Program Files\Samsung\Samsung Magician\SamsungMagician.exe'); Args=@() },
        @{ Name='Western Digital Dashboard'; Paths=@('C:\Program Files\Western Digital\SSD Dashboard\WD SSD Dashboard.exe'); Args=@() },
        @{ Name='Crucial Storage Executive'; Paths=@('C:\Program Files\Crucial\Crucial Storage Executive\StorageExecutive.exe'); Args=@() },
        @{ Name='Intel Driver and Support Assistant'; Paths=@('C:\Program Files (x86)\Intel\Driver and Support Assistant\DSATray.exe'); Args=@() },
        @{ Name='AMD Software'; Paths=@('C:\Program Files\AMD\CNext\CNext\RadeonSoftware.exe'); Args=@() },
        @{ Name='NVIDIA App'; Paths=@('C:\Program Files\NVIDIA Corporation\NVIDIA app\CEF\NVIDIA App.exe'); Args=@() },
        @{ Name='GeForce Experience'; Paths=@('C:\Program Files\NVIDIA Corporation\NVIDIA GeForce Experience\NVIDIA GeForce Experience.exe'); Args=@() },
        @{ Name='Logitech G HUB'; Paths=@('C:\Program Files\LGHUB\lghub.exe'); Args=@() },
        @{ Name='Razer Synapse'; Paths=@('C:\Program Files (x86)\Razer\Synapse3\WPFUI\Framework\Razer Synapse 3 Host.exe'); Args=@() },
        @{ Name='SteelSeries GG'; Paths=@('C:\Program Files\SteelSeries\GG\SteelSeriesGG.exe'); Args=@() }
    )

    foreach ($candidate in $candidates) {
        $hit = $candidate.Paths | Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($hit) {
            try {
                Write-Host ('  Found ' + $candidate.Name + '. Launching...') -ForegroundColor Gray
                if ($candidate.Args.Count -gt 0) {
                    Start-Process -FilePath $hit -ArgumentList $candidate.Args -WindowStyle Minimized
                } else {
                    Start-Process -FilePath $hit -WindowStyle Minimized
                }
                Write-Ok ($candidate.Name + ' launched')
            } catch {
                Write-Err ($candidate.Name + ' launch failed: ' + $_)
            }
        } else {
            Write-Host ('  ' + $candidate.Name + ' not found (skipped)') -ForegroundColor Gray
        }
    }

    Write-Host ''
}

function Check-BIOS {
    Write-Section '[9/12] Checking motherboard firmware online...'
    try {
        $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
        $bios = Get-CimInstance -ClassName Win32_BIOS
        $baseBoard = Get-CimInstance -ClassName Win32_BaseBoard

        Write-Host ('  Manufacturer: ' + $computerSystem.Manufacturer) -ForegroundColor Gray
        Write-Host ('  Model: ' + $computerSystem.Model) -ForegroundColor Gray
        Write-Host ('  Motherboard: ' + $baseBoard.Product) -ForegroundColor Gray
        Write-Host ('  BIOS Version: ' + $bios.SMBIOSBIOSVersion) -ForegroundColor Gray
        Write-Host ('  BIOS Date: ' + $bios.ReleaseDate) -ForegroundColor Gray
        Write-Host ''

        $latestBios = Get-LatestASRockBiosInfo -BoardProduct $baseBoard.Product -BoardManufacturer $baseBoard.Manufacturer
        if ($latestBios) {
            Write-Host ('  Latest online BIOS version: ' + $latestBios.LatestVersion) -ForegroundColor Gray
            Write-Host ('  Latest online BIOS date: ' + $latestBios.LatestDate) -ForegroundColor Gray
            Write-Host ('  Source: ' + $latestBios.SourceUrl) -ForegroundColor Gray

            $cmp = Compare-VersionStrings -A $bios.SMBIOSBIOSVersion -B $latestBios.LatestVersion
            if ($cmp -lt 0) {
                Write-Warn ('BIOS update available: installed ' + $bios.SMBIOSBIOSVersion + ', latest ' + $latestBios.LatestVersion)
            } elseif ($cmp -eq 0) {
                Write-Ok 'BIOS is up to date'
            } else {
                Write-Ok 'Installed BIOS appears newer than parsed support-table value'
            }
        } else {
            Write-Warn 'Online BIOS lookup was not available for this board or vendor.'
        }
    } catch {
        Write-Err ('Failed to get motherboard information: ' + $_)
    }
    Write-Host ''
}

function Check-GPUDrivers {
    Write-Section '[10/12] Checking graphics driver versions online...'
    try {
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
            Write-Host ''
            return
        }

        Write-Host ('  Graphics Card: ' + $physicalGpu.Name) -ForegroundColor Gray
        Write-Host ('  Driver Version (Windows): ' + $physicalGpu.DriverVersion) -ForegroundColor Gray
        Write-Host ('  Driver Date: ' + $physicalGpu.DriverDate) -ForegroundColor Gray
        Write-Host ''

        if ($physicalGpu.Name -match 'NVIDIA|GeForce|Quadro|RTX|GTX') {
            $installedNvidiaVersion = Get-NvidiaDisplayVersionFromWindowsVersion -DriverVersion $physicalGpu.DriverVersion
            if ($installedNvidiaVersion) {
                Write-Host ('  Interpreted NVIDIA driver version: ' + $installedNvidiaVersion) -ForegroundColor Gray
            }
            $nvidiaLatest = Get-NvidiaLatestDriverVersion
            if ($nvidiaLatest -and $nvidiaLatest.LatestVersion) {
                Write-Host ('  Latest NVIDIA version found online: ' + $nvidiaLatest.LatestVersion) -ForegroundColor Gray
                Write-Host ('  Source: ' + $nvidiaLatest.SourceUrl) -ForegroundColor Gray
                if ($installedNvidiaVersion) {
                    $cmp = Compare-VersionStrings -A $installedNvidiaVersion -B $nvidiaLatest.LatestVersion
                    if ($cmp -lt 0) {
                        Write-Warn ('NVIDIA driver update available: installed ' + $installedNvidiaVersion + ', latest ' + $nvidiaLatest.LatestVersion)
                    } elseif ($cmp -eq 0) {
                        Write-Ok 'NVIDIA driver appears up to date'
                    } else {
                        Write-Ok 'Installed NVIDIA driver appears newer than parsed website version'
                    }
                }
            } else {
                Write-Warn 'Could not determine the latest NVIDIA driver automatically'
            }
        } elseif ($physicalGpu.Name -match 'AMD|Radeon|RX') {
            $amdInfo = Get-AmdDriverInfo
            Write-Warn $amdInfo.Note
            Write-Host ('  AMD Drivers and Support: ' + $amdInfo.SourceUrl) -ForegroundColor Gray
            Write-Host ('  AMD Auto-Detect Tool: ' + $amdInfo.ToolUrl) -ForegroundColor Gray
        } elseif ($physicalGpu.Name -match 'Intel|Intel\(R\)|Arc') {
            $intelInfo = Get-IntelDriverInfo
            Write-Warn $intelInfo.Note
            Write-Host ('  Intel Driver and Support Assistant: ' + $intelInfo.SourceUrl) -ForegroundColor Gray
            Write-Host ('  Intel Download Center: ' + $intelInfo.DownloadCenter) -ForegroundColor Gray
        } else {
            Write-Warn 'GPU manufacturer not automatically detected.'
        }
    } catch {
        Write-Err ('Failed to get graphics card information: ' + $_)
    }
    Write-Host ''
}

function Update-MicrosoftStoreApps {
    Write-Section '[11/12] Checking Microsoft Store source and app coverage...'
    Invoke-IfCommandExists -CommandName 'winget' -MissingMessage 'winget not found (skipped)' -Action {
        try {
            Write-Host '  winget source list:' -ForegroundColor Gray
            winget source list
            Write-Ok 'winget source list completed'
        } catch {
            Write-Err ('winget source list failed: ' + $_)
        }
    }
    Write-Host ''
}

function Finish-Up {
    Write-Section '[12/12] Final summary...'
    Write-Host ('  Log file: ' + $script:LogFile) -ForegroundColor Gray
    Write-Host '  Some updates may require a reboot or follow-up run.' -ForegroundColor Gray
    Write-Host '  Vendor utility launches may continue checking in the background.' -ForegroundColor Gray
    Write-Host ''
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host 'Update Script Completed' -ForegroundColor Cyan
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host ''
    try {
        Stop-Transcript | Out-Null
    } catch {}
}

Start-Sleep -Seconds 1
Write-Host '========================================' -ForegroundColor Cyan
Write-Host 'Starting System Update Script v2' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan
Write-Host ''

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
Finish-Up

Write-Host 'Press any key to exit...' -ForegroundColor Cyan
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')