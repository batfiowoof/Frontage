@echo off
REM One process, two AI players, nobody watching. The broadest smoke test there is.
set "RTSPROJ=%~dp0."
"C:\Users\bojid\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64.exe" --path "%RTSPROJ%" --headless --script res://tests/ai_harness.gd -- --turns 15
exit /b %ERRORLEVEL%
