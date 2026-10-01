@echo off
setlocal
cd /d "%~dp0"

where docker >nul 2>nul || (
  echo Docker Desktop is required and was not found.
  echo Install Docker Desktop, restart this computer if requested, then open this file again.
  pause
  exit /b 1
)

if not exist .env (
  where python >nul 2>nul || (
    echo Initial configuration has not been created and Python is unavailable.
    echo This preview launcher will be replaced by the signed graphical server manager.
    pause
    exit /b 1
  )
  set /p CLEARPOCKET_HOST=Enter the hostname or IP address used to reach this PC: 
  python configure.py --allowed-hosts "%CLEARPOCKET_HOST%" --bind-address 0.0.0.0 || (pause & exit /b 1)
)

docker compose --env-file .env up -d || (pause & exit /b 1)
echo.
echo ClearPocket Server started. Opening its household setup page...
start "" "http://127.0.0.1:8080/admin"
pause
