@echo off
setlocal
title Private Advisor - Static Analysis
cd /d "%~dp0app"

echo ================================================
echo   Private Advisor - Flutter Analyze
echo ================================================
echo.
echo This checks all Dart code for errors WITHOUT a full
echo C++ build. Much faster than running the launcher.
echo.

call flutter analyze

echo.
echo ================================================
echo Analysis finished.
echo If there are errors, please copy the output above.
echo ================================================
pause
