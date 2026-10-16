@ECHO OFF
SETLOCAL
SET distributionDir=%~dp0
SET beePowerShellScript=%distributionDir%bee.ps1

REM .NET can randomly hang on Windows while initializing ICU globalization data:
REM https://github.com/dotnet/runtime/issues/89194. Using NLS instead avoids it.
SET DOTNET_SYSTEM_GLOBALIZATION_USENLS=1

PowerShell -NoProfile -ExecutionPolicy Bypass -File "%beePowerShellScript%" %*
