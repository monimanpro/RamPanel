# RamPanel installer: copies the app to %LOCALAPPDATA%\Programs\RamPanel, adds Start menu and desktop shortcuts
# and an entry in Settings > Apps. Nothing here touches the BIOS.
param([switch]$Silent)      # -Silent: no questions, no launch at the end (for tests / scripted installs)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$src     = $PSScriptRoot
$dest    = Join-Path $env:LOCALAPPDATA 'Programs\RamPanel'
$version = '1.2.0'
$title   = 'RamPanel — установка'
$verified = 'Lenovo Legion R7000P 16ADR10 (83LT) · BIOS RLCN31WW · AMD Ryzen 9 8945HX'
function Msg($text, $buttons = 'OK', $icon = 'Information') {
    if ($Silent) { Write-Host ($text -replace "`r`n", ' | '); return $(if ($buttons -eq 'YesNo') { if ($text -match '^Установить') { 'Yes' } else { 'No' } } else { 'OK' }) }
    [Windows.Forms.MessageBox]::Show($text, $title, $buttons, $icon)
}

try {
    # 1. what this computer will get: verified / experimental / read-only (the panel decides the same way at start)
    $p = Get-CimInstance Win32_ComputerSystemProduct; $b = Get-CimInstance Win32_BIOS; $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $c = ("$($cpu.Name)" -replace '\s+', ' ').Trim()
    $here = "$($p.Vendor) $($p.Version) ($($p.Name)) · BIOS $($b.SMBIOSBIOSVersion) · $c"
    $isAmd = "$($cpu.Manufacturer)" -match 'AMD' -or $c -match 'AMD|Ryzen'
    $hasAod = [bool](Get-CimInstance -Namespace root\wmi -ClassName AMD_ACPI -ErrorAction SilentlyContinue)
    $isVerified = ("$($p.Name)".Trim() -eq '83LT') -and ("$($b.SMBIOSBIOSVersion)".Trim() -eq 'RLCN31WW') -and ($c -match 'Ryzen 9 8945HX')
    $mode = if (-not $isAmd) { 'Процессор не AMD — RamPanel на нём не заработает.' }
            elseif ($isVerified) { 'Проверенное устройство — полная поддержка.' }
            elseif ($hasAod) { 'Устройство не проверено, но интерфейс разгона AMD есть — будет экспериментальный режим: запись только после явного согласия, на свой риск.' }
            else { 'В BIOS нет интерфейса разгона AMD — панель будет только показывать тайминги.' }
    $intro = "Установить RamPanel $version?`r`n`r`nЭтот компьютер: $here`r`n$mode`r`n`r`nПроверено на: $verified"
    if ((Msg $intro 'YesNo' $(if ($isVerified) { 'Question' } else { 'Warning' })) -ne 'Yes') { return }

    # 2. close a running panel and copy the files (settings and profiles of an older install are kept)
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'RamPanel\.ps1' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force $dest | Out-Null
    foreach ($f in 'RamPanel.ps1', 'Get-LiveTimings.ps1', 'ZenStates-Core.dll', 'inpoutx64.dll', 'RamPanel.vbs', 'RamPanel.ico', 'uninstall.ps1', 'README.txt') {
        Copy-Item (Join-Path $src $f) (Join-Path $dest $f) -Force
    }

    # 3. shortcuts (run as administrator: the panel reads BIOS variables and the AMD interface)
    $sh = New-Object -ComObject WScript.Shell
    $links = @((Join-Path ([Environment]::GetFolderPath('Programs')) 'RamPanel.lnk'), (Join-Path ([Environment]::GetFolderPath('Desktop')) 'RamPanel.lnk'))
    foreach ($l in $links) {
        $lnk = $sh.CreateShortcut($l)
        $lnk.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
        $lnk.Arguments = "`"$dest\RamPanel.vbs`""
        $lnk.WorkingDirectory = $dest
        $lnk.IconLocation = "$dest\RamPanel.ico,0"
        $lnk.Description = 'RamPanel — тайминги, скорость памяти и FCLK для AMD Ryzen'
        $lnk.Save()
        $bytes = [IO.File]::ReadAllBytes($l); $bytes[0x15] = $bytes[0x15] -bor 0x20; [IO.File]::WriteAllBytes($l, $bytes)
    }

    # 4. entry in Settings > Apps
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\RamPanel'
    New-Item -Path $key -Force | Out-Null
    $size = [int]((Get-ChildItem $dest -Recurse -File | Measure-Object Length -Sum).Sum / 1KB)
    $vals = @{
        DisplayName = 'RamPanel — тайминги памяти для AMD Ryzen'; DisplayVersion = $version
        Publisher = 'Claude (Anthropic) по инициативе кожаного'; DisplayIcon = "$dest\RamPanel.ico"; InstallLocation = $dest
        UninstallString = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dest\uninstall.ps1`""
        InstallDate = (Get-Date -Format 'yyyyMMdd'); Comments = "Проверено на: $verified"
    }
    foreach ($k in $vals.Keys) { Set-ItemProperty -Path $key -Name $k -Value $vals[$k] }
    Set-ItemProperty -Path $key -Name EstimatedSize -Value $size -Type DWord
    Set-ItemProperty -Path $key -Name NoModify -Value 1 -Type DWord
    Set-ItemProperty -Path $key -Name NoRepair -Value 1 -Type DWord

    # 5. an existing "open at sign-in" task is pointed at the installed copy
    if (Get-ScheduledTask -TaskName 'RamPanel' -ErrorAction SilentlyContinue) {
        $a = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$dest\RamPanel.vbs`"" -WorkingDirectory $dest
        Set-ScheduledTask -TaskName 'RamPanel' -Action $a | Out-Null
    }

    if ((Msg "RamPanel $version установлен в:`r`n$dest`r`n`r`nЯрлыки — в меню «Пуск» и на рабочем столе. Удалить можно в «Параметры → Приложения».`r`n`r`nЗапустить сейчас?" 'YesNo' 'Information') -eq 'Yes') {
        Start-Process (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList "`"$dest\RamPanel.vbs`"" -WorkingDirectory $dest
    }
} catch {
    Msg "Установка не удалась:`r`n$($_.Exception.Message)" 'OK' 'Error' | Out-Null
}
