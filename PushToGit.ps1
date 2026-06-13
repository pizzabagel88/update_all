#requires -Version 5.1

param(
    [Parameter(Mandatory=$false)]
    [string]$RemoteUrl = "https://github.com/pizzabagel88/update_all.git",

    [string]$Message = "Update System scripts to v3.1.1"
)

$ErrorActionPreference = "Stop"

try {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "Git is not installed or not in the system PATH."
    }

    if (-not (Test-Path ".git")) {
        Write-Host "Initializing Git repository..." -ForegroundColor Cyan
        git init
        git branch -M main
    }

    Write-Host "Staging files..." -ForegroundColor Cyan
    git add .

    if (git status --porcelain) {
        Write-Host "Committing changes..." -ForegroundColor Cyan
        git commit -m $Message
    } else {
        Write-Host "No changes to commit." -ForegroundColor Yellow
    }

    Write-Host "Configuring remote and pushing to main..." -ForegroundColor Cyan
    if (git remote) { git remote remove origin }
    git remote add origin $RemoteUrl
    git push -u origin main -f

    Write-Host "Push successful!" -ForegroundColor Green
} catch {
    Write-Error "Git operation failed: $($_.Exception.Message)"
}