#!/bin/sh
# Parse-check all scripts (autoload identifier errors are expected in this mode)
cd "$(dirname "$0")/.."
timeout 120 ./tools/godot/Godot_v4.7.2-stable_win64_console.exe --headless --path game --script res://tests/check.gd 2>&1 | grep -A1 "SCRIPT ERROR" | grep -v "^--" | paste - - | grep -v "found: Game|found: Sfx|found: Net\|found: Sfx\|Failed to compile depended" | sed 's/\s\+at: GDScript::reload/ @/'
