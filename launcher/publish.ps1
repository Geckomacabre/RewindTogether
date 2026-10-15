<#
  Builds, tests and publishes the launcher as ONE self-contained exe:
      launcher\dist\RewindTogetherLauncher.exe

    powershell -ExecutionPolicy Bypass -File launcher\publish.ps1 [-SkipTests]

  No .NET install is needed on the player's PC. steam_api64.dll is NOT bundled - the launcher
  loads the game's own copy at runtime.
#>
param([switch] $SkipTests)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

if (-not $SkipTests) {
    dotnet test RewindTogether.Launcher.sln -c Release --nologo
    if ($LASTEXITCODE -ne 0) { throw "Tests failed - not publishing." }
}

# The launcher carries the release's version (mod.json), so its footer, the release it came
# with and the self-update all talk about the same number.
$modJson = Join-Path $PSScriptRoot '..\Mods\RewindTogether\mod.json'
$version = (Get-Content $modJson -Raw | ConvertFrom-Json).version
if ($version -notmatch '^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$') { throw "mod.json version '$version' is not x.y.z." }
$prefix, $suffix = $version.Split('-', 2)

$dist = Join-Path $PSScriptRoot 'dist'
dotnet publish RewindTogether.Launcher\RewindTogether.Launcher.csproj -c Release -r win-x64 --self-contained true `
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true `
    -p:DebugType=None -p:DebugSymbols=false -p:SatelliteResourceLanguages=en `
    "-p:VersionPrefix=$prefix" "-p:VersionSuffix=$suffix" `
    -o $dist --nologo
if ($LASTEXITCODE -ne 0) { throw "Publish failed." }

$exe = Get-Item (Join-Path $dist 'RewindTogetherLauncher.exe')
"{0}  {1:N1} MB  sha256 {2}" -f $exe.FullName, ($exe.Length / 1MB), (Get-FileHash $exe.FullName -Algorithm SHA256).Hash.ToLower()
