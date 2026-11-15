@echo off
rem As Run-PCHealth, plus read-only DISM ScanHealth and SFC /verifyonly (10-20 minutes).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Get-PCHealth.ps1" -DeepScan %*
