@echo off
rem Build RewindNative.dll into the mod folder.
rem Needs the MSVC x64 toolset (Visual Studio 2022 with "Desktop development with C++",
rem or the 2022 Build Tools with the VC tools workload).
setlocal
set "PATH=%PATH%;C:\Program Files (x86)\Microsoft Visual Studio\Installer;C:\Windows\System32"
set "VSDEVCMD="
for /f "usebackq delims=" %%i in (`vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSDIR=%%i"
if not defined VSDIR (
  echo No Visual Studio with the C++ x64 tools was found.
  exit /b 1
)
call "%VSDIR%\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1

cd /d "%~dp0"
set "OUT=%~dp0..\..\Mods\RewindTogether\native"
if not exist "%OUT%" mkdir "%OUT%"
if not exist obj mkdir obj

rem The native test first, when its source is here (the release does not ship
rem it): the thunks run inside the Blueprint VM, where a wrong decision is a
rem crash, so a build whose decisions fail the test is not made at all.
if exist test_standin.cpp (
  cl /nologo /O2 /MT /EHsc /W4 /std:c++17 /Fo"obj\\" /Fe"obj\test_standin.exe" test_standin.cpp /link /INCREMENTAL:NO
  if errorlevel 1 exit /b 1
  obj\test_standin.exe
  if errorlevel 1 exit /b 1
)
rem The same for the UE4SS name-cache repair, which writes into UE4SS's memory.
if exist test_namecache.cpp (
  cl /nologo /O2 /MT /EHsc /W4 /std:c++17 /Fo"obj\\" /Fe"obj\test_namecache.exe" test_namecache.cpp /link /INCREMENTAL:NO
  if errorlevel 1 exit /b 1
  obj\test_namecache.exe
  if errorlevel 1 exit /b 1
)

rem /MT: static CRT, so the DLL needs nothing installed beyond what the game has.
cl /nologo /LD /O2 /MT /EHsc /W4 /std:c++17 /Fo"obj\\" RewindNative.cpp ^
   /link /OUT:"%OUT%\RewindNative.dll" /IMPLIB:obj\RewindNative.lib /PDB:obj\RewindNative.pdb /PDBALTPATH:%%_PDB%% /DEBUG /INCREMENTAL:NO /OPT:REF /OPT:ICF
if errorlevel 1 exit /b 1
echo Built %OUT%\RewindNative.dll
