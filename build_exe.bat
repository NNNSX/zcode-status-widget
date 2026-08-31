@echo off
rem Compatibility entrypoint. The PowerShell script discovers Python and has no machine-specific paths.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\build-release.ps1"
if errorlevel 1 (
  echo Build failed.
  pause
  exit /b 1
)
echo.
echo Done. Output: dist\ZCodeStatusLight.exe
pause
