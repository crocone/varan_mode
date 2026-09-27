@echo off
rem Build the Windows executable into build\VaranMod.exe
"%~dp0tools\godot\Godot_v4.7.2-stable_win64_console.exe" --headless --path "%~dp0game" --export-release "Windows Desktop" ..\build\VaranMod.exe
