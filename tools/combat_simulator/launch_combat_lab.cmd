@echo off
setlocal
pushd "%~dp0"
python combat_lab.py %*
if errorlevel 1 pause
popd
endlocal
