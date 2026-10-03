@echo off
title Enable Windows Developer Mode
setlocal

net session >nul 2>&1
if not %errorlevel%==0 goto elevate
goto apply

:elevate
echo Requesting administrator rights. Please click YES on the UAC prompt.
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
exit /b

:apply
echo ================================================
echo   Enable Windows Developer Mode
echo ================================================
echo.
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" /v AllowDevelopmentWithoutDevLicense /t REG_DWORD /d 1 /f
if errorlevel 1 goto failed
echo.
echo SUCCESS - Developer Mode is now ON.
echo.
echo Next steps:
echo   1. Close this window.
echo   2. Run the launcher again.
goto done

:failed
echo.
echo FAILED - could not write the registry key.
echo Please open Settings and turn on Developer Mode manually.

:done
echo.
pause
