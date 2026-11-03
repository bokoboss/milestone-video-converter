@echo off
setlocal
set "PSModulePath="
cd /d "%~dp0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -File "%~dp0App.ps1"
set "converter_exit=%errorlevel%"
if not "%converter_exit%"=="0" (
  echo The converter could not start. Run setup.bat and read the error above.
  echo Organization PowerShell policies are respected. No policy was changed.
  pause
)
exit /b %converter_exit%
