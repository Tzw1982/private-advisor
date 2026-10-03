@echo off
title Install ATL Component for VS Build Tools
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
echo   Install C++ ATL Component
echo ================================================
echo.
echo Reason: flutter_secure_storage_windows needs atlstr.h
echo Target: VS Build Tools 2022
echo.
echo This will download and install the ATL component.
echo It may take several minutes. Please wait.
echo.

if not exist "E:\vs_BuildTools.exe" goto noboot
goto useboot

:noboot
echo Bootstrapper not found at E:\vs_BuildTools.exe
echo Please re-download it from:
echo   https://aka.ms/vs/17/release/vs_BuildTools.exe
goto done

:useboot
"E:\vs_BuildTools.exe" --quiet --wait --norestart --nocache --installPath "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools" --add Microsoft.VisualStudio.Component.VC.ATL
if errorlevel 1 goto failed

echo.
echo ================================================
echo   SUCCESS - ATL component installed.
echo   Now run the launcher again.
echo ================================================
goto done

:failed
echo.
echo ================================================
echo   FAILED
echo   Please open Visual Studio Installer manually,
echo   click Modify, then Individual components,
echo   and check C++ ATL for latest v143 build tools.
echo ================================================

:done
echo.
pause
