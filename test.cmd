@echo off
REM Headless test gate.  Exit 0 = green.
"C:\Users\bojid\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64.exe" --path "%~dp0." --headless --script res://tests/run.gd
