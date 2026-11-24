@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch_pair.ps1" -Backend Fusion -PlayerExe "%~dp0..\out\packages\sync-lab-fusion-local-win-x64\current\SyncLabFusionLocal.exe" %*
if errorlevel 1 pause
