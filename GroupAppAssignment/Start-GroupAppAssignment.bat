@echo off
rem Starts the tool without an execution-policy prompt. Arguments are passed on, e.g. -GroupId AllUsers
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Manage-GroupAppAssignment.ps1" %*
