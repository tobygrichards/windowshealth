@echo off
rem Watches the sensors for 20 minutes while you use the PC (play a game), then opens the dashboard.
rem Generates no load of its own. Change the number to watch for longer or shorter.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Get-PCHealth.ps1" -WatchMinutes 20 %*
