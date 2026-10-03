@echo off
setlocal
title Private Advisor - Build Windows Release
cd /d "%~dp0"

set "SRC=%~dp0"
set "DST=E:\APP\private_advisor_build"
set "PRJ=%DST%\app"
set "OUTDIR=%SRC%app\build\windows\x64\runner\Release"

echo ==================================================
echo   Private Advisor - Build Windows Release
echo ==================================================
echo.
echo Why this script builds in another folder:
echo   This project folder path contains non-ASCII characters.
echo   The Flutter release build chain breaks on such paths.
echo   So the source is mirrored into an ASCII-only folder,
echo   the build runs there, and the result is copied back.
echo   Your project files are not modified.
echo.

echo Step 1 of 6 : mirror source to %DST%
if not exist "%DST%" mkdir "%DST%"
robocopy "%SRC%app" "%DST%\app" /MIR /XD build .dart_tool ephemeral /R:1 /W:1 /NFL /NDL /NJH /NJS /NP >nul
if errorlevel 8 goto mirrorfail
robocopy "%SRC%advisor_core" "%DST%\advisor_core" /MIR /XD .dart_tool /R:1 /W:1 /NFL /NDL /NJH /NJS /NP >nul
if errorlevel 8 goto mirrorfail
robocopy "%SRC%advisor_storage" "%DST%\advisor_storage" /MIR /XD .dart_tool /R:1 /W:1 /NFL /NDL /NJH /NJS /NP >nul
if errorlevel 8 goto mirrorfail
echo   OK
echo.

pushd "%PRJ%"

echo Step 2 of 6 : flutter clean
call flutter clean >nul 2>nul
echo   OK
echo.

echo Step 3 of 6 : flutter pub get
call flutter pub get
if errorlevel 1 goto fail_pub
echo.

echo Step 4 of 6 : flutter build windows --release
echo   This step takes several minutes. Do not close this window.
echo.
call flutter build windows --release
if errorlevel 1 goto fail_build
echo.

popd

echo Step 5 of 6 : copy result back to this project
robocopy "%PRJ%\build\windows\x64\runner\Release" "%OUTDIR%" /MIR /R:1 /W:1 /NFL /NDL /NJH /NJS /NP >nul
if errorlevel 8 goto copyfail
echo   OK - copied to app\build\windows\x64\runner\Release
echo.

echo Step 6 of 6 : open output folder
echo ------------------------------------------------
echo  BUILD OK
echo.
echo  Run this file:
echo    app\build\windows\x64\runner\Release\private_advisor.exe
echo.
echo  Note: keep the whole Release folder together.
echo        Do not move the exe out on its own.
echo ------------------------------------------------
start "" "%OUTDIR%"
goto done

:mirrorfail
echo.
echo FAILED at step 1 - could not mirror the source folder.
echo.

:fail_pub
popd
echo.
echo FAILED at flutter pub get. Read the output above.
echo.
goto done

:fail_build
popd
echo.
echo FAILED at flutter build. Read the output above.
echo.
goto done

:copyfail
echo.
echo The build succeeded but copying the result back failed.
echo You can still run the exe here:
echo   %PRJ%\build\windows\x64\runner\Release
echo.

:done
echo.
echo Build script finished.
pause
