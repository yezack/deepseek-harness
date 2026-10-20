# Assemble the transfer bundle that is uploaded to the offline build host.
#
# The bundle carries the release tarballs, the build index, the UOS build
# scripts, and the extras list. It is assembled from the repository's packed
# output plus `_stage/uos`, so the offline host receives exactly what the
# current build produced.
#
# Usage: pwsh -File _stage/assemble-bundle.ps1
[CmdletBinding()]
param(
  [string]$Workspace = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$repo = Join-Path $Workspace 'deepseek-harness'
$src = Join-Path $Workspace '_stage\uos'
$bundle = Join-Path $Workspace '_stage\uos-bundle'
$out = Join-Path $Workspace '_stage\dsh-tarballs.tar.gz'

if (-not (Test-Path (Join-Path $repo 'dist\npm'))) { throw "缺少 $repo\dist\npm；先运行 release:pack" }

if (Test-Path $bundle) { Remove-Item $bundle -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Join-Path $bundle 'npm'), (Join-Path $bundle 'npm-vendor') | Out-Null
Copy-Item (Join-Path $repo 'dist\npm\*.tgz') (Join-Path $bundle 'npm') -Force
Copy-Item (Join-Path $repo 'dist\npm-vendor\*.tgz') (Join-Path $bundle 'npm-vendor') -Force
Copy-Item (Join-Path $src 'tarball-index.json') $bundle -Force

# Every build-side script travels with the bundle so the offline host runs the
# same versions that produced the index.
foreach ($file in 'materialize-uos.sh', 'make-package.sh', 'install.sh', 'seed-profile.sh', 'README.txt', 'extras.json', 'offline-test.sh', 'patch-remote-mobile.mjs') {
  $from = Join-Path $src $file
  if (-not (Test-Path $from)) { throw "缺少 $from" }
  Copy-Item $from $bundle -Force
}

# Prebuilt tarballs for packages that are not on any reachable registry. The
# extras list refers to them with `file:` specs resolved against the bundle root.
$extrasDir = Join-Path $src 'extras'
if (Test-Path $extrasDir) {
  Copy-Item $extrasDir (Join-Path $bundle 'extras') -Recurse -Force
}

if (Test-Path $out) { Remove-Item $out -Force }
Push-Location $bundle
try { tar -czf $out . } finally { Pop-Location }

$npmCount = (Get-ChildItem (Join-Path $bundle 'npm') -Filter '*.tgz' -File).Count
$vendorCount = (Get-ChildItem (Join-Path $bundle 'npm-vendor') -Filter '*.tgz' -File).Count
$extras = (Get-Content (Join-Path $bundle 'extras.json') -Raw | ConvertFrom-Json)
Write-Host ("npm {0} / vendor {1} / extras {2}" -f $npmCount, $vendorCount, $extras.Count)
Write-Host ("bundle: {0} 文件, {1:N1} MB" -f (Get-ChildItem $bundle -Recurse -File).Count, ((Get-Item $out).Length / 1MB))
Write-Host $out
