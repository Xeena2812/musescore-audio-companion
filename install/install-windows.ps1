# Registers the audiocompanion:// URL scheme for the current user (no admin).
# Changes: copies the launcher to %LOCALAPPDATA%\AudioCompanion\ and writes
# HKCU\Software\Classes\audiocompanion registry keys.
# Undo with: .\install-windows.ps1 -Uninstall
param([switch]$Uninstall)
$dest = Join-Path $env:LOCALAPPDATA 'AudioCompanion'
$key  = 'HKCU:\Software\Classes\audiocompanion'

if ($Uninstall) {
    Remove-Item -Recurse -Force $dest, $key -ErrorAction SilentlyContinue
    Write-Host 'Removed.'; exit 0
}

New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'audiocompanion-launcher.ps1') $dest -Force
New-Item -Force "$key\shell\open\command" | Out-Null
Set-ItemProperty $key -Name '(default)' -Value 'URL:Audio Companion'
Set-ItemProperty $key -Name 'URL Protocol' -Value ''
$cmd = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$dest\audiocompanion-launcher.ps1`" `"%1`""
Set-ItemProperty "$key\shell\open\command" -Name '(default)' -Value $cmd
Write-Host 'Installed. Test: Start-Process audiocompanion://start'
