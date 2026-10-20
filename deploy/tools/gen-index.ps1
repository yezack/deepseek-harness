# 生成 tarball 索引：扫描 release:pack 产物，读出每个 tarball 的真实 name/version
# 用法: pwsh -File gen-index.ps1 -Repo <repo> -Out <index.json>
param(
  [Parameter(Mandatory=$true)][string]$Repo,
  [Parameter(Mandatory=$true)][string]$Out
)
$ErrorActionPreference = 'Stop'
$dist = Join-Path $Repo 'dist'
$entries = @()
foreach ($sub in @(@{Dir='npm'; Rel='npm'}, @{Dir='npm-vendor'; Rel='npm-vendor'})) {
  $d = Join-Path $dist $sub.Dir
  if (-not (Test-Path $d)) { Write-Host "  [跳过] $($sub.Dir) 不存在"; continue }
  $files = Get-ChildItem $d -Filter '*.tgz' -File
  Write-Host "  $($sub.Dir): $($files.Count) 个 tarball"
  foreach ($f in $files) {
    $json = & tar -xOzf $f.FullName 'package/package.json' 2>$null
    if (-not $json) { Write-Host "    [警告] 无法读取 $($f.Name)"; continue }
    $obj = $json | ConvertFrom-Json
    $entries += [pscustomobject]@{
      name    = $obj.name
      version = $obj.version
      file    = "$($sub.Rel)/$($f.Name)"
    }
  }
}
$entries = $entries | Sort-Object name
$jsonOut = $entries | ConvertTo-Json -Depth 4
[IO.File]::WriteAllText($Out, $jsonOut, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "  索引条目: $($entries.Count)  ->  $Out"
Write-Host "  样例:"
$entries | Select-Object -First 5 | ForEach-Object { Write-Host "    $($_.name)@$($_.version)  $($_.file)" }
