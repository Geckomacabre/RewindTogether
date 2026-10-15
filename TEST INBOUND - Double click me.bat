@echo off
setlocal

title Rewind Together - is his traffic reaching me?

echo.
echo   ============================================================
echo     Rewind Together  -  inbound traffic test
echo   ============================================================
echo.
echo   This answers the one question left: do your friend's
echo   packets actually reach this PC?
echo.
echo   BEFORE YOU START:
echo     * be hosting (in your store, F7 pressed)
echo     * have your friend ready, in his own store
echo.
echo   It watches UDP 27015 for 60 seconds. When it says so,
echo   tell him to press F5.
echo.
echo   Windows will ask for Administrator - packet capture
echo   needs it. Nothing is installed and nothing is sent
echo   anywhere.
echo.
pause

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Test-Inbound.ps1"

endlocal
