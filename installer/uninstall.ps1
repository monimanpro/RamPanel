# Removes RamPanel: files, shortcuts, the Settings > Apps entry and the "open at sign-in" task.
# Memory settings already written to the BIOS stay as they are.
param([switch]$Silent)
Add-Type -AssemblyName System.Windows.Forms
$dest  = $PSScriptRoot
$title = 'RamPanel — удаление'
$q = "Удалить RamPanel?`r`n`r`nБудут удалены программа, ярлыки, сохранённые профили и настройки окна.`r`nТайминги, уже записанные в BIOS, останутся как есть."
if (-not $Silent -and [Windows.Forms.MessageBox]::Show($q, $title, 'YesNo', 'Question') -ne 'Yes') { return }
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'RamPanel\.ps1' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Unregister-ScheduledTask -TaskName 'RamPanel' -Confirm:$false -ErrorAction SilentlyContinue
foreach ($l in @((Join-Path ([Environment]::GetFolderPath('Programs')) 'RamPanel.lnk'), (Join-Path ([Environment]::GetFolderPath('Desktop')) 'RamPanel.lnk'))) {
    Remove-Item $l -Force -ErrorAction SilentlyContinue
}
Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\RamPanel' -Recurse -Force -ErrorAction SilentlyContinue
Set-Location $env:TEMP
# the folder is removed by a short-lived helper after this script exits
$cmd = "Start-Sleep 2; Remove-Item -LiteralPath '$($dest -replace "'", "''")' -Recurse -Force -ErrorAction SilentlyContinue"
Start-Process powershell.exe -ArgumentList '-NoProfile', '-WindowStyle', 'Hidden', '-Command', $cmd -WindowStyle Hidden
if (-not $Silent) { [void][Windows.Forms.MessageBox]::Show('RamPanel удалён.', $title, 'OK', 'Information') } else { 'removed' }
