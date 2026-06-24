# Package the Windows release as a self-contained distributable zip (#96).
#
# Flutter's Windows build is NOT self-contained — it depends on the MSVC runtime
# (msvcp140.dll / vcruntime140*.dll), which a clean machine may not have, so the
# exe fails to launch. This bundles those redistributable DLLs into the zip.
#
# Run AFTER `flutter build windows --release`:
#   & C:\Dev\flutter-meshcore\bin\dart.bat   # (not needed)
#   pwsh -File scripts/package-windows.ps1
$ErrorActionPreference = 'Stop'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rel  = Join-Path $root 'build\windows\x64\runner\Release'
$exe  = Join-Path $rel 'offband_meshcore.exe'
if (-not (Test-Path $exe)) {
  throw "Run 'flutter build windows --release' first - missing $exe"
}

# Release name = the pubspec build-name (e.g. 1.1.2-beta.1), without the +build.
$verLine = (Select-String -Path (Join-Path $root 'pubspec.yaml') -Pattern '^version:\s*(\S+)').Matches[0].Groups[1].Value
$buildName = ($verLine -split '\+')[0]
$name = "OffbandMeshcore-$buildName"

$dist  = Join-Path $root 'dist'
$stage = Join-Path $dist $name
New-Item -ItemType Directory -Force $dist | Out-Null
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
Copy-Item -Recurse -Path $rel -Destination $stage

# Bundle the VC++ runtime (Microsoft-redistributable copies from VS BuildTools).
$crt = Get-ChildItem 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Redist\MSVC' -Directory |
  Where-Object { $_.Name -match '^\d' } | Sort-Object Name -Descending |
  ForEach-Object { Get-ChildItem (Join-Path $_.FullName 'x64') -Directory -Filter '*CRT*' } |
  Select-Object -First 1
if (-not $crt) { throw 'VC++ redist CRT folder not found under VS BuildTools' }
foreach ($d in 'msvcp140.dll','vcruntime140.dll','vcruntime140_1.dll','msvcp140_1.dll') {
  Copy-Item (Join-Path $crt.FullName $d) (Join-Path $stage $d) -Force
}

$zip = Join-Path $dist "$name-win-x64.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path $stage -DestinationPath $zip -CompressionLevel Optimal
Remove-Item -Recurse -Force $stage
$mb = [math]::Round((Get-Item $zip).Length / 1MB, 1)
Write-Output "Packaged: $zip ($mb MB) - VC++ runtime bundled, extracts to $name\"
