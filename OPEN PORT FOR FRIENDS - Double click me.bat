@echo off
setlocal

title Rewind Together - open your port for friends

echo.
echo   ============================================================
echo     Rewind Together  -  let friends connect directly
echo   ============================================================
echo.
echo   This lets people join you over the internet with no VPN and
echo   nothing to pay for. It will:
echo.
echo     * allow the game through Windows Firewall (UDP 27015)
echo     * ask your router to forward that port here, using UPnP
echo     * print the address to give your friend
echo.
echo   Windows will ask for Administrator - that is for the
echo   firewall rule. Nothing is installed and nothing is sent
echo   anywhere except one lookup of your own public IP.
echo.
echo   To undo it later, run:  Disable-DirectHosting.bat
echo.
pause

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Enable-DirectHosting.ps1"

echo.
echo   If a second window opened, read the address in THAT window.
echo.
pause
endlocal
