@echo off
rem Mo cong cu KUONTPL Builder (build file .ipa cho iPad)
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0tools\JarBoxBuilder.ps1"
