@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"
set PUB_CACHE=E:\flutter\.pub-cache

:: Create log file
set LOGFILE="%~dp0run_windows.log"
echo ======================================== > %LOGFILE%
echo %date% %time% >> %LOGFILE%
echo ======================================== >> %LOGFILE%

:: Create necessary directories
mkdir "windows\flutter\ephemeral\.plugin_symlinks" 2>nul

:: Run Flutter
echo Starting Flutter app... >> %LOGFILE%
E:\flutter\bin\flutter.bat run -d windows >> %LOGFILE% 2>&1

:: Check exit code
if !ERRORLEVEL! neq 0 (
  echo ERROR: Flutter run failed with exit code !ERRORLEVEL! >> %LOGFILE%
  echo. >> %LOGFILE%
  echo ========== ERROR LOG ========== >> %LOGFILE%
  tail -20 %LOGFILE% >> %LOGFILE% 2>&1
  echo.
  echo ERROR: Failed to start application.
  echo Please check the log file: %LOGFILE%
  pause
) else (
  echo SUCCESS: Application exited normally. >> %LOGFILE%
)

endlocal
