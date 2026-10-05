@echo off
rem Installs Peak Optimizations into Program Files and adds it to the Start menu (it will ask for administrator rights).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1"
