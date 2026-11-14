@echo off
setlocal EnableExtensions
title RootLawk installer
cd /d "%~dp0"
color 07

echo.
echo   ==============================================
echo     RootLawk - password protection for your MPC
echo   ==============================================
echo.
echo   Jailbroken MPCs (Hakai) come with NO root password, so anyone on
echo   your WiFi can take full control. RootLawk sets a password, keeps it
echo   after restarts, and closes the maker's hidden login.
echo.

if not exist "rootlawk.sh" (
  echo   [x] rootlawk.sh must be in the same folder as this installer.
  goto end
)
where ssh >nul 2>nul || (
  echo   [x] This PC is missing the SSH tool.
  echo       Windows Settings ^> System ^> Optional features ^> Add "OpenSSH Client",
  echo       then run this installer again.
  goto end
)

set "SAVED=%USERPROFILE%\.rootlawk-mpc-address"
set "MPC="
if exist "%SAVED%" set /p MPC=<"%SAVED%"

echo   Your MPC and this PC must be on the same WiFi.
echo   Find the MPC's address on the MPC: Menu ^> Preferences ^> Wi-Fi
echo   (it looks like 192.168.1.23).
echo.
:askaddr
set "IN="
if defined MPC (
  set /p "IN=  MPC address [press Enter for %MPC%]: "
) else (
  set /p "IN=  MPC address: "
)
if defined IN set "MPC=%IN%"
if not defined MPC goto askaddr
echo %MPC%| findstr /r /x "[0-9A-Za-z.-]*" >nul || (
  echo   [x] That doesn't look like an address. Use only numbers and dots, like 192.168.1.23
  set "MPC="
  goto askaddr
)
>"%SAVED%" echo %MPC%

echo.
echo   What would you like to do?
echo     1) Install or update RootLawk  (recommended)
echo     2) Show status
echo     3) Remove RootLawk
echo.
set "CH=1"
set /p "CH=  Choose 1-3 [1]: "
set "OPT=--install"
if "%CH%"=="2" set "OPT=--status"
if "%CH%"=="3" set "OPT=--uninstall"

set "SSHOPTS=-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
echo.
echo   Connecting to root@%MPC% ...
echo   It asks for your MPC root password twice: once to copy RootLawk over,
echo   once to run it. (RootLawk may then ask a third time to confirm it's you.)
echo   If you have never set one, it won't ask.
echo   (Nothing shows on screen while you type a password. That's normal.)
echo.
scp %SSHOPTS% -q "rootlawk.sh" root@%MPC%:/tmp/rootlawk.sh 2>nul
if errorlevel 1 scp -O %SSHOPTS% -q "rootlawk.sh" root@%MPC%:/tmp/rootlawk.sh
if errorlevel 1 goto failed

ssh -t %SSHOPTS% root@%MPC% "sh /tmp/rootlawk.sh %OPT%; rc=$?; rm -f /tmp/rootlawk.sh; exit $rc"
if errorlevel 1 (
  echo.
  echo   [!] RootLawk stopped before finishing. Read the lines above.
  goto end
)
goto end

:failed
echo.
echo   [x] Couldn't reach the MPC at %MPC%.
echo       - Is the MPC on, and on the same WiFi as this PC?
echo       - Is the address right? (Menu ^> Preferences ^> Wi-Fi on the MPC)
echo       - Is SSH turned on in Hakai?
echo       - If you see "REMOTE HOST IDENTIFICATION HAS CHANGED" (normal after
echo         re-installing the firmware), run this once, then try again:
echo             ssh-keygen -R %MPC%

:end
echo.
pause
