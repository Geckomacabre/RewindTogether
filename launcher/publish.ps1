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

$dist = Join-Path $PSScriptRoot 'dist'
dotnet publish RewindTogether.Launcher\RewindTogether.Launcher.csproj -c Release -r win-x64 --self-contained true `
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true `
    -p:DebugType=None -p:DebugSymbols=false -p:SatelliteResourceLanguages=en `
    -o $dist --nologo
if ($LASTEXITCODE -ne 0) { throw "Publish failed." }

$exe = Get-Item (Join-Path $dist 'RewindTogetherLauncher.exe')
"{0}  {1:N1} MB  sha256 {2}" -f $exe.FullName, ($exe.Length / 1MB), (Get-FileHash $exe.FullName -Algorithm SHA256).Hash.ToLower()
