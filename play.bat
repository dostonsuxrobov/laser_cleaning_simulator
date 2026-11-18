@echo off
rem Starts Laser Cleaning Simulator. Double-click me.
rem Uses the Godot 4 install in C:\Godot, or "godot" from PATH if that is missing.
setlocal
set "GODOT=C:\Godot\Godot_v4.7.2-stable_win64.exe"
if exist "%GODOT%" (
    start "" "%GODOT%" --path "%~dp0."
) else (
    godot --path "%~dp0."
)
