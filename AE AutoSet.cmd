@echo off
rem Opens the settings window and (re)creates the desktop / Start menu shortcuts.
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0app\AE-AutoSet.ps1" -EnsureShortcuts
