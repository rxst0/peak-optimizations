@echo off
rem Starts Peak Optimizations (it will ask for administrator rights).
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0PeakOptimizations.ps1"
