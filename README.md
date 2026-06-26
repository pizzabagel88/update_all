# System Update Script v3.1.1

A comprehensive PowerShell script for updating Windows systems, package managers, and development tools.

## Features

Automatically updates:
- **WinGet** - Windows Package Manager sources and all packages
- **Python** - pip and all outdated packages
- **Windows Update** - Windows and Microsoft updates including drivers
- **Chocolatey** - All packages
- **Scoop** - All packages
- **npm** - Global packages
- **pnpm** - Global packages
- **Yarn** - Global packages
- **.NET** - Global tools (if SDK is installed)
- **Rust/Cargo** - Installed binaries via cargo-install-update
- **Poetry** - Python dependency manager
- **uv** - Modern Python package installer
- **Steam** - Games and client
- **Vendor Utilities** - Lenovo Vantage, Dell Update, etc.
- **Microsoft Store** - Apps and coverage

## Usage

### Basic Usage
```powershell
.\UpdateAll_v3.ps1
```

### Run with Batch File
```batch
UpdateAll_v3.bat
```

## Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `Mode` | String | `All` | Update mode: `Fast`, `Full`, `Drivers`, `All` |
| `AuditOnly` | Switch | `false` | Dry run - shows what would be updated without making changes |
| `PromptForRiskyActions` | Switch | `false` | Prompt before risky operations like Windows Update |
| `SkipVendorUtilities` | Switch | `false` | Skip vendor utility updates (Lenovo, Dell, etc.) |
| `SkipSteam` | Switch | `false` | Skip Steam updates |
| `SkipWindowsUpdate` | Switch | `false` | Skip Windows Update and driver updates |
| `SkipWebLookup` | Switch | `false` | Skip web-based version lookups |
| `SkipWingetExport` | Switch | `false` | Skip winget package export to snapshot |
| `SkipInventory` | Switch | `false` | Skip machine inventory snapshot |
| `LogRetentionDays` | Int | `30` | Number of days to retain logs and snapshots |

## Modes

- **All** - Runs all update sections (default)
- **Fast** - Core, Packages, Tools, Snapshots only (skips Windows Update and drivers)
- **Full** - Core, Packages, Tools, Windows, Snapshots (includes Windows Update but not drivers)
- **Drivers** - Drivers, Snapshots, Core only (focused on driver updates)

## Examples

### Fast update (skip Windows Update)
```powershell
.\UpdateAll_v3.ps1 -Mode Fast
```

### Audit only (dry run)
```powershell
.\UpdateAll_v3.ps1 -AuditOnly
```

### Skip Windows Update and vendor utilities
```powershell
.\UpdateAll_v3.ps1 -SkipWindowsUpdate -SkipVendorUtilities
```

### Prompt before risky actions
```powershell
.\UpdateAll_v3.ps1 -PromptForRiskyActions
```

## Output

The script creates:
- **Logs**: `Desktop\Updater\logs\update-log-{timestamp}.txt` - Detailed transcript of all operations
- **Snapshots**: `Desktop\Updater\snapshots\inventory-{timestamp}.json` - Machine inventory and versions
- **Winget Export**: `Desktop\Updater\snapshots\winget-export-{timestamp}.json` - Winget package list

## Requirements

- **PowerShell 5.1+** (built into Windows 10/11)
- **Administrator privileges** (required for Windows Update and some package managers)
- **Internet connection**

## Notes

- The script automatically detects which package managers are installed and only updates those present
- Some sections require administrator privileges (Windows Update, driver updates)
- Logs and snapshots are automatically cleaned up after 30 days (configurable)
- The script checks for pending reboots before and after updates
- WinGet updates now show progress indicators listing packages being upgraded

## Version History

### v3.1.1
- Fixed leaked boolean output from helper calls
- Fixed Python Packages final summary logic
- Added progress indicators for WinGet package updates (shows packages being upgraded)
- Behavior otherwise unchanged from v3.1.0

## License

This script is provided as-is for system maintenance purposes.
