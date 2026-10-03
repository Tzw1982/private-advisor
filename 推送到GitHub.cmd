@echo off
setlocal
title Private Advisor - Push to GitHub
cd /d "%~dp0"

set "REPO=https://github.com/Tzw1982/private-advisor.git"

echo ==================================================
echo   Private Advisor - Push to GitHub
echo ==================================================
echo.
echo Target repository:
echo   %REPO%
echo.
echo BEFORE running this script, create the empty repository:
echo   1. Open  https://github.com/new
echo   2. Repository name : private-advisor
echo   3. Visibility      : Public
echo   4. Do NOT tick "Add a README file" or any .gitignore
echo   5. Click the green "Create repository" button
echo.
echo Press any key when the empty repository exists...
pause >nul
echo.

echo Step 1 of 4 : check the target repository
git ls-remote %REPO% >nul 2>nul
if errorlevel 1 goto norepo
echo   OK - repository found
echo.

echo Step 2 of 4 : set remote and rename branch to main
git remote remove origin >nul 2>nul
git remote add origin %REPO%
git branch -M main
echo   OK
echo.

echo Step 3 of 4 : push files
echo   A browser window may open and ask you to sign in to GitHub.
echo   Sign in once; the push continues automatically after that.
echo.
git push -u origin main
if errorlevel 1 goto pushfail
echo.

echo Step 4 of 4 : result
echo ------------------------------------------------
echo  PUSH OK
echo.
echo  Repository:
echo    https://github.com/Tzw1982/private-advisor
echo ------------------------------------------------
goto done

:norepo
echo.
echo Repository not found or not reachable.
echo Create it first at https://github.com/new
echo.

:pushfail
echo.
echo Push failed. Read the output above.
echo.

:done
echo.
echo Script finished.
pause
