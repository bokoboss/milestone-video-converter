@echo off
setlocal
set "PSModulePath="
cd /d "%~dp0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -File "%~dp0Setup.ps1" %*
set "converter_exit=%errorlevel%"
if not "%converter_exit%"=="0" echo Setup did not pass. Read the message above. No system policy was changed.
pause
exit /b %converter_exit%
