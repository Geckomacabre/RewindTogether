@echo off
setlocal
title Rewind Together - close the port again
echo.
echo   Removing the firewall rule and the router port forward.
echo.
pause
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Enable-DirectHosting.ps1" -Remove
echo.
pause
endlocal
