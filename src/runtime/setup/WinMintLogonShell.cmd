@echo off
REM WinMint first-logon shell: Winlogon starts this instead of explorer.exe so the
REM provisioning splash is the first session UI. Fail-open restores explorer.
set "SCRIPT=%~dp0WinMintLogonShell.ps1"
set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if exist "%PWSH%" (
  "%PWSH%" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SCRIPT%"
  exit /b %ERRORLEVEL%
)
REM Fail-open: no PowerShell 7 — restore Explorer so the machine stays usable.
reg add "HKCU\Software\Microsoft\Windows NT\CurrentVersion\Winlogon" /v Shell /t REG_SZ /d explorer.exe /f >nul 2>&1
start "" explorer.exe
exit /b 1
