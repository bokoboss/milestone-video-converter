@echo off
setlocal
set "PSModulePath="
cd /d "%~dp0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -File "%~dp0tests\Run-Tests.ps1"
if errorlevel 1 goto done
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -File "%~dp0tests\Run-V3Tests.ps1"
:done
set "converter_exit=%errorlevel%"
pause
exit /b %converter_exit%
