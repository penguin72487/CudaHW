@echo off
setlocal
powershell -ExecutionPolicy Bypass -File "%~dp0code_runner.ps1"
exit /b %errorlevel%
