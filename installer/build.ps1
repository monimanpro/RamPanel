# Builds dist\RamPanel-Setup-<version>.exe: a small C# setup (compiled with the .NET Framework csc that ships
# with Windows) that carries all files as embedded resources and runs install.ps1.
#
# Needs ZenStates-Core.dll and inpoutx64.dll in ..\vendor (see vendor\README.md), or pass -VendorDir.
param([string]$VendorDir = (Join-Path (Split-Path $PSScriptRoot) 'vendor'))
$ErrorActionPreference = 'Stop'
$here    = $PSScriptRoot
$repo    = Split-Path $here
$src     = Join-Path $repo 'src'
$version = ([regex]::Match((Get-Content (Join-Path $src 'RamPanel.ps1') -Raw), "\`$appVersion\s*=\s*'([^']+)'")).Groups[1].Value
$stage   = Join-Path $env:TEMP 'rampanel_build\stage'
$dist    = Join-Path $repo 'dist'
$exe     = Join-Path $dist "RamPanel-Setup-$version.exe"
$csc     = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$bom     = New-Object Text.UTF8Encoding($true)

foreach ($dll in 'ZenStates-Core.dll', 'inpoutx64.dll') {
    if (-not (Test-Path (Join-Path $VendorDir $dll))) { throw "$dll not found in $VendorDir - see vendor\README.md" }
}
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $stage, $dist | Out-Null

& (Join-Path $here 'make-icon.ps1') -Out (Join-Path $stage 'RamPanel.ico')
# scripts with Russian text must be UTF-8 with BOM for Windows PowerShell 5.1
foreach ($f in @(@("$src\RamPanel.ps1", 'RamPanel.ps1'), @("$src\Get-LiveTimings.ps1", 'Get-LiveTimings.ps1'),
                 @("$here\install.ps1", 'install.ps1'), @("$here\uninstall.ps1", 'uninstall.ps1'), @("$repo\docs\README-install.txt", 'README.txt'))) {
    [IO.File]::WriteAllText((Join-Path $stage $f[1]), [IO.File]::ReadAllText($f[0], [Text.Encoding]::UTF8), $bom)
}
Copy-Item "$here\RamPanel.vbs" $stage
Copy-Item (Join-Path $VendorDir 'ZenStates-Core.dll'), (Join-Path $VendorDir 'inpoutx64.dll') $stage

$files = Get-ChildItem $stage -File
$cscArgs = @('/nologo', '/codepage:65001', '/target:winexe', '/optimize+', "/out:$exe", "/win32icon:$($stage)\RamPanel.ico",
             "/win32manifest:$here\Setup.manifest", '/r:System.Windows.Forms.dll') +
           @($files | ForEach-Object { "/resource:$($_.FullName),$($_.Name)" }) + @("$here\Setup.cs")
Remove-Item $exe -Force -ErrorAction SilentlyContinue
& $csc @cscArgs
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $exe)) { throw "csc failed (exit $LASTEXITCODE)" }
"built: $exe  ($([math]::Round((Get-Item $exe).Length / 1KB)) KB; files: $(($files | ForEach-Object Name) -join ', '))"
