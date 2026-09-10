@echo off
chcp 65001 >nul
setlocal
rem 在本机当前目录生成带管理员标志的快捷方式。
rem 快捷方式里存的是绝对路径，没法跨机器复制，所以改成到本地现生成。
set "DIR=%~dp0"
if "%DIR:~-1%"=="\" set "DIR=%DIR:~0,-1%"
if not exist "%DIR%\ApexTool.ps1" (
    echo.
    echo   [错误] 同目录下找不到 ApexTool.ps1，请把压缩包整个解压后再运行。
    echo.
    pause
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
 "$d='%DIR%';" ^
 "$p=Join-Path $d 'Apex 优化工具.lnk';" ^
 "$s=New-Object -ComObject WScript.Shell;" ^
 "$l=$s.CreateShortcut($p);" ^
 "$l.TargetPath=\"$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe\";" ^
 "$l.Arguments='-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File \"'+$d+'\ApexTool.ps1\"';" ^
 "$l.WorkingDirectory=$d;" ^
 "$l.IconLocation=(Join-Path $d 'app.ico')+',0';" ^
 "$l.Save();" ^
 "$b=[IO.File]::ReadAllBytes($p); $b[21]=$b[21] -bor 0x20; [IO.File]::WriteAllBytes($p,$b);" ^
 "Write-Host ''; Write-Host '  快捷方式已生成: ' -NoNewline; Write-Host $p"
echo.
echo   完成。以后双击那个云朵图标启动即可。
echo.
pause
