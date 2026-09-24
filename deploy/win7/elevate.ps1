param([Parameter(Mandatory=$true)][string]$ScriptPath)
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$p  = New-Object Security.Principal.WindowsPrincipal($id)
$isAdmin = $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) {
  Write-Host "  Elevation: already running as Administrator"
  exit 0
}
Write-Host "  Elevation: not elevated - requesting UAC elevation..."
try {
  $ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
  $cmdArgs = "-NoProfile -ExecutionPolicy Bypass -Command `"& '" + $ScriptPath + "' --elevated`""
  Start-Process -FilePath $ps -Verb RunAs -ArgumentList $cmdArgs
  Write-Host "  Elevation: a new elevated window was started"
  exit 10
} catch {
  Write-Host ("  Elevation: FAILED - " + $_.Exception.Message)
  Write-Host "  Elevation: right-click install.cmd and choose 'Run as administrator'"
  exit 1
}