@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ssmc.ps1" %*
set "SSMC_EXIT=%ERRORLEVEL%"
if not "%SSMC_EXIT%"=="0" pause
exit /b %SSMC_EXIT%
