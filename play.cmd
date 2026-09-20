@echo off
REM play.cmd          two windowed clients, campaign dealt as soon as both are up
REM play.cmd demo     two windowed clients dropped straight into a staged battle
setlocal
set "RTSPROJ=%~dp0."
set "RTSMODE=%~1"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$godot = 'C:\Users\bojid\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64.exe';$proj = '\"' + $env:RTSPROJ + '\"';$mode = $env:RTSMODE;$hostArgs = @('--path', $proj, '--', '--host');if ($mode -eq 'demo') { $hostArgs += '--demo-battle' } else { $hostArgs += '--autostart' };$h = Start-Process -FilePath $godot -ArgumentList $hostArgs -PassThru;Start-Sleep -Milliseconds 2500;if ($h.HasExited) { Write-Host ('host failed to start, exit ' + $h.ExitCode); exit 1 };$c = Start-Process -FilePath $godot -ArgumentList @('--path', $proj, '--', '--join', '127.0.0.1') -PassThru;Start-Sleep -Milliseconds 2500;if ($c.HasExited) { Write-Host ('client failed to start, exit ' + $c.ExitCode); exit 1 };Write-Host ('two windows up: host pid ' + $h.Id + ', client pid ' + $c.Id + '. Close them when done.')"
exit /b %ERRORLEVEL%
