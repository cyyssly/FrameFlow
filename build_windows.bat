@echo off
cd /d "%~dp0"
set PUB_CACHE=E:\flutter\.pub-cache
E:\flutter\bin\flutter.bat build windows
pause
