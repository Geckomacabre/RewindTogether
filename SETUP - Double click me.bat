@echo off
setlocal

title Rewind Together - Setup

echo.
echo   ==========================================================
echo     Rewind Together  -  co-op multiplayer for Retro Rewind
echo   ==========================================================
echo.
echo   This will:
echo     * find your Retro Rewind install
echo     * set up UE4SS (using a zip you already downloaded)
echo     * install the co-op mod
echo.
echo   Nothing is downloaded. Nothing outside the game is changed.
echo.
pause

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-RewindTogether.ps1"
set RESULT=%ERRORLEVEL%

echo.
if "%RESULT%"=="0" goto ok
if "%RESULT%"=="2" goto needue4ss
goto failed

:ok
echo   ==========================================================
echo     Done. Launch Retro Rewind from Steam and have fun.
echo   ==========================================================
echo.
echo   ONE of you hosts. Decide who first - the host's save is
echo   the one everybody plays in, and the only one that saves.
echo.
echo   HOST:  load your save, walk into your store, press F7.
echo          Then run "CHECK CONNECTION - Double click me.bat"
echo          and send your friend the address it prints.
echo.
echo   JOIN:  load YOUR OWN save first and get inside your store
echo          - not the main menu, it does nothing there - then
echo          press ~ or F10 and type:   rt.join THEIR-ADDRESS
echo.
echo   Joining by Steam ID does NOT work on this build. Use the
echo   address from the connection check.
echo.
goto end

:needue4ss
echo   ----------------------------------------------------------
echo     UE4SS is needed and no copy was found.
echo   ----------------------------------------------------------
echo.
echo   1. A browser window will open in a moment.
echo   2. Download the newest "UE4SS_v*.zip" (NOT the zDEV one).
echo   3. Leave it in your Downloads folder.
echo   4. Run this Setup again - it will unpack it for you.
echo.
pause
start "" "https://github.com/UE4SS-RE/RE-UE4SS/releases/latest"
goto end

:failed
echo   Setup did not finish (code %RESULT%). See the messages above.
echo.

:end
pause
endlocal
