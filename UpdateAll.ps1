# System Update Script
# This script updates winget packages, Python packages, and other software

# Ensure script is running
Start-Sleep -Seconds 1

Write-Host '========================================' -ForegroundColor Cyan
Write-Host 'Starting System Update Script' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan
Write-Host ''

# Section 1: Update Windows Packages via winget
Write-Host '[1/5] Updating Windows packages via winget...' -ForegroundColor Yellow
try {
    winget upgrade --all --accept-source-agreements --accept-package-agreements
    Write-Host '✓ Winget updates completed' -ForegroundColor Green
} catch {
    Write-Host '✗ Winget update failed: $_' -ForegroundColor Red
}
Write-Host ''

# Section 2: Update pip
Write-Host '[2/5] Updating pip...' -ForegroundColor Yellow
try {
    python -m pip install --upgrade pip
    Write-Host '✓ pip updated' -ForegroundColor Green
} catch {
    Write-Host '✗ pip update failed: $_' -ForegroundColor Red
}
Write-Host ''

# Section 3: Update Python packages
Write-Host '[3/5] Updating outdated Python packages...' -ForegroundColor Yellow
try {
    $outdated = python -m pip list --outdated 2>$null
    if ($LASTEXITCODE -eq 0) {
        $packages = $outdated | Select-String -Pattern '^[a-zA-Z]' | ForEach-Object {
            ($_ -split '\s+')[0]
        }
        if ($packages) {
            foreach ($pkg in $packages) {
                Write-Host "  Updating $pkg..." -ForegroundColor Gray
                python -m pip install --upgrade $pkg
            }
            Write-Host '✓ Python packages updated' -ForegroundColor Green
        } else {
            Write-Host '✓ No outdated Python packages found' -ForegroundColor Green
        }
    } else {
        Write-Host '✗ Failed to check for outdated packages' -ForegroundColor Red
    }
} catch {
    Write-Host '✗ Python package update failed: $_' -ForegroundColor Red
}
Write-Host ''

# Section 4: Update Windows Update and Drivers (requires admin)
Write-Host '[4/5] Checking for Windows Updates and Drivers (requires admin)...' -ForegroundColor Yellow
try {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    
    if ($isAdmin) {
        # Try to use PSWindowsUpdate if available
        if (Get-Module -ListAvailable -Name PSWindowsUpdate) {
            # Check if module is already loaded and remove it first
            if (Get-Module -Name PSWindowsUpdate) {
                Remove-Module PSWindowsUpdate -Force -ErrorAction SilentlyContinue
            }
            Import-Module PSWindowsUpdate -Force
            Write-Host '  Checking for Windows updates and drivers...' -ForegroundColor Gray
            Get-WindowsUpdate -AcceptAll -Install -AutoReboot
            Write-Host '✓ Windows Update and Driver check completed' -ForegroundColor Green
        } else {
            # Try to install PSWindowsUpdate
            Write-Host '  Installing PSWindowsUpdate module...' -ForegroundColor Gray
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser -ErrorAction SilentlyContinue
            Install-Module -Name PSWindowsUpdate -Force -Scope CurrentUser -AllowClobber -ErrorAction SilentlyContinue
            if (Get-Module -ListAvailable -Name PSWindowsUpdate) {
                Import-Module PSWindowsUpdate -Force
                Write-Host '  Checking for Windows updates and drivers...' -ForegroundColor Gray
                Get-WindowsUpdate -AcceptAll -Install -AutoReboot
                Write-Host '✓ Windows Update and Driver check completed' -ForegroundColor Green
            } else {
                Write-Host '  PSWindowsUpdate installation failed. Skipping Windows Update.' -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host '⚠ Not running as administrator. Windows Update and Driver updates skipped.' -ForegroundColor Yellow
        Write-Host '  To enable Windows Update and Driver updates, run this script as Administrator.' -ForegroundColor Gray
    }
} catch {
    Write-Host '✗ Windows Update failed: $_' -ForegroundColor Red
    Write-Host '  You can manually run Windows Update from Settings.' -ForegroundColor Gray
}
Write-Host ''

# Section 5: Check for other package managers
Write-Host '[5/8] Checking for other package managers...' -ForegroundColor Yellow

# Check for Chocolatey
try {
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        Write-Host '  Chocolatey found. Updating packages...' -ForegroundColor Gray
        choco upgrade all -y
        Write-Host '✓ Chocolatey packages updated' -ForegroundColor Green
    } else {
        Write-Host '  Chocolatey not found (skipped)' -ForegroundColor Gray
    }
} catch {
    Write-Host '✗ Chocolatey update failed: $_' -ForegroundColor Red
}

# Check for Scoop
try {
    if (Get-Command scoop -ErrorAction SilentlyContinue) {
        Write-Host '  Scoop found. Updating packages...' -ForegroundColor Gray
        scoop update *
        Write-Host '✓ Scoop packages updated' -ForegroundColor Green
    } else {
        Write-Host '  Scoop not found (skipped)' -ForegroundColor Gray
    }
} catch {
    Write-Host '✗ Scoop update failed: $_' -ForegroundColor Red
}

# Check for npm
try {
    if (Get-Command npm -ErrorAction SilentlyContinue) {
        Write-Host '  npm found. Updating global packages...' -ForegroundColor Gray
        npm update -g
        Write-Host '✓ npm global packages updated' -ForegroundColor Green
    } else {
        Write-Host '  npm not found (skipped)' -ForegroundColor Gray
    }
} catch {
    Write-Host '✗ npm update failed: $_' -ForegroundColor Red
}

Write-Host ''

# Section 6: Update Steam games
Write-Host '[6/8] Checking for Steam games...' -ForegroundColor Yellow
try {
    $steamPaths = @(
        "$env:ProgramFiles (x86)\Steam\steam.exe",
        "$env:ProgramFiles\Steam\steam.exe"
    )
    $steamPath = $steamPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    
    if ($steamPath) {
        Write-Host '  Steam found. Checking for game updates...' -ForegroundColor Gray
        # Launch Steam with silent update flag
        Start-Process $steamPath -ArgumentList '-silent', '-update' -NoNewWindow -Wait
        Write-Host '✓ Steam games updated (Steam will continue updating in background)' -ForegroundColor Green
    } else {
        Write-Host '  Steam not found (skipped)' -ForegroundColor Gray
    }
} catch {
    Write-Host '✗ Steam update failed: $_' -ForegroundColor Red
}
Write-Host ''

# Section 7: Check motherboard firmware
Write-Host '[7/8] Checking motherboard firmware...' -ForegroundColor Yellow
try {
    $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
    $bios = Get-CimInstance -ClassName Win32_BIOS
    $baseBoard = Get-CimInstance -ClassName Win32_BaseBoard
    
    Write-Host "  Manufacturer: $($computerSystem.Manufacturer)" -ForegroundColor Gray
    Write-Host "  Model: $($computerSystem.Model)" -ForegroundColor Gray
    Write-Host "  BIOS Version: $($bios.SMBIOSBIOSVersion)" -ForegroundColor Gray
    Write-Host "  BIOS Date: $($bios.ReleaseDate)" -ForegroundColor Gray
    Write-Host "  Motherboard: $($baseBoard.Product)" -ForegroundColor Gray
    Write-Host ''
    Write-Host '  To check for firmware updates, visit your manufacturer website:' -ForegroundColor Yellow
    Write-Host "  - ASRock: https://www.asrock.com/" -ForegroundColor Gray
    Write-Host "  - ASUS: https://www.asus.com/" -ForegroundColor Gray
    Write-Host "  - Gigabyte: https://www.gigabyte.com/" -ForegroundColor Gray
    Write-Host "  - MSI: https://www.msi.com/" -ForegroundColor Gray
    Write-Host "  - Dell: https://www.dell.com/support" -ForegroundColor Gray
    Write-Host "  - HP: https://support.hp.com/" -ForegroundColor Gray
    Write-Host '✓ Motherboard information displayed' -ForegroundColor Green
} catch {
    Write-Host '✗ Failed to get motherboard information: $_' -ForegroundColor Red
}
Write-Host ''

# Section 8: Check graphics card firmware/drivers
Write-Host '[8/8] Checking graphics card firmware/drivers...' -ForegroundColor Yellow
try {
    $gpu = Get-CimInstance -ClassName Win32_VideoController | Select-Object -First 1
    if ($gpu) {
        Write-Host "  Graphics Card: $($gpu.Name)" -ForegroundColor Gray
        Write-Host "  Driver Version: $($gpu.DriverVersion)" -ForegroundColor Gray
        Write-Host "  Driver Date: $($gpu.DriverDate)" -ForegroundColor Gray
        Write-Host ''
        
        # Detect GPU manufacturer
        $gpuName = $gpu.Name
        if ($gpuName -match 'NVIDIA|GeForce|Quadro|RTX|GTX') {
            Write-Host '  NVIDIA GPU detected. Check for updates at: https://www.nvidia.com/Download/index.aspx' -ForegroundColor Yellow
        } elseif ($gpuName -match 'AMD|Radeon|RX') {
            Write-Host '  AMD GPU detected. Check for updates at: https://www.amd.com/support' -ForegroundColor Yellow
        } elseif ($gpuName -match 'Intel|Intel\(R\)|Arc') {
            Write-Host '  Intel GPU detected. Check for updates at: https://www.intel.com/content/www/us/en/download-center/home.html' -ForegroundColor Yellow
        } else {
            Write-Host '  GPU manufacturer not automatically detected. Check manufacturer website for driver updates.' -ForegroundColor Yellow
        }
        Write-Host '✓ Graphics card information displayed' -ForegroundColor Green
    } else {
        Write-Host '  No graphics card detected' -ForegroundColor Gray
    }
} catch {
    Write-Host '✗ Failed to get graphics card information: $_' -ForegroundColor Red
}
Write-Host ''

# Summary
Write-Host '========================================' -ForegroundColor Cyan
Write-Host 'Update Script Completed' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan
Write-Host ''
Write-Host 'Note: Some updates may require a system restart.' -ForegroundColor Yellow
Write-Host 'For driver and firmware updates, check your manufacturer website.' -ForegroundColor Yellow
Write-Host ''
Write-Host 'Press any key to exit...' -ForegroundColor Cyan
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
