@echo off
setlocal

title Rewind Together - Steam tunnel (HOST)

echo.
echo   ============================================================
echo     Rewind Together  -  Steam tunnel  (HOST side)
echo   ============================================================
echo.
echo   This carries the game's traffic over Steam's relay, so your
echo   friend does not need to reach your router at all.
echo.
echo   ORDER MATTERS:
echo     1. Start the game, load your save, get into your store
echo     2. Press F7 to host, wait for the store to reload
echo     3. THEN leave this window open
echo     4. Tell your friend to start his tunnel and press F5
echo.
echo   Leave this window open the whole time you are playing.
echo.
pause

set /p PEER=   Your friend's SteamID64 (17 digits): 
"%~dp0tunnel\RewindTunnel.exe" --host --peer %PEER% --game-port 27015

echo.
echo   Tunnel stopped.
pause
endlocal
