@echo off
setlocal

title Rewind Together - connection check

echo.
echo   ============================================================
echo     Rewind Together  -  is my game actually joinable?
echo   ============================================================
echo.
echo   Run this WHILE THE GAME IS HOSTING - load your save, get
echo   inside your store, press F7, wait for the store to reload,
echo   and then run this.
echo.
echo   It reads the socket the game really has open, so it tells
echo   you the truth about which port your friend has to use
echo   instead of trusting a config file.
echo.
pause

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Check-Connection.ps1"

endlocal
