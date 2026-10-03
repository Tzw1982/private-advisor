@echo off
setlocal
title Private Advisor - Windows Launcher
cd /d "%~dp0app"

echo ==================================================
echo   Private Advisor - Windows Desktop Launcher
echo ==================================================
echo.
echo Working folder: %CD%
echo.

echo Step 1 of 3 : generate windows platform files
if not exist "windows" call flutter create --platforms=windows .
echo.

echo Step 2 of 3 : flutter pub get
call flutter pub get
if errorlevel 1 goto pubfail
echo.

echo Step 3 of 3 : flutter run -d windows
echo.
echo ------------------------------------------------
echo  While the app is running, press keys here:
echo    r  = hot reload after code changes
echo    R  = hot restart
echo    q  = quit
echo ------------------------------------------------
echo.
call flutter run -d windows
goto done

:pubfail
echo.
echo FAILED at flutter pub get. Read the output above.
echo.

:done
echo.
echo Launcher finished.
pause
