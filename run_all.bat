@echo off
setlocal
rem 精簡包裝：呼叫同資料夾下的 PowerShell 主流程腳本。
powershell -ExecutionPolicy Bypass -File "%~dp0code_runner.ps1"
exit /b %errorlevel%
