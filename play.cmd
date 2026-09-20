@echo off
REM play.cmd          two windowed clients, campaign dealt as soon as both are up
REM play.cmd demo     two windowed clients dropped straight into a staged battle
setlocal
set "RTSPROJ=%~dp0."
set "RTSMODE=%~1"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$godot = 'C:\Users\bojid\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64.exe';$proj = $env:RTSPROJ;$mode = $env:RTSMODE;$hostArgs = @('--path', $proj, '--', '--host');if ($mode -eq 'demo') { $hostArgs += '--demo-battle' } else { $hostArgs += '--autostart' };Start-Process -FilePath $godot -ArgumentList $hostArgs | Out-Null;Start-Sleep -Milliseconds 2500;Start-Process -FilePath $godot -ArgumentList @('--path', $proj, '--', '--join', '127.0.0.1') | Out-Null;Write-Host 'two windows launched: host (left) and client. Close them when done.'"
