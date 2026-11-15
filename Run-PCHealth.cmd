@echo off
rem Runs the passive PC health check and opens the dashboard.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Get-PCHealth.ps1" %*
