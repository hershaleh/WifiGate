@echo off
rem WifiGate installer launcher. Double-click this file (after extracting the ZIP).
start "" /b powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Install.ps1"
