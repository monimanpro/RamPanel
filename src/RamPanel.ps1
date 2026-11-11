# RamPanel - тайминги, скорость памяти и FCLK для ноутбуков и ПК на AMD Ryzen.
#
# Значения уходят в BIOS через штатный интерфейс разгона AMD (WMI-класс AMD_ACPI, им же пользуется Ryzen Master)
# и вступают в силу только после перезагрузки. Скрипт сам ничего не тестирует и не перезагружает без команды.
#
# Уровни поддержки:
#   verified     - устройство из списка $Verified: команды, диапазоны и раскладка настроек BIOS проверены опытом,
#                  после записи настройки BIOS сверяются байт в байт;
#   experimental - любой AMD с интерфейсом AMD_ACPI и памятью DDR4/DDR5: команды и диапазоны берутся у самого BIOS,
#                  запись только после явного согласия; если раскладка настроек неизвестна, сверки до перезагрузки нет;
#   readonly     - остальное: только просмотр работающих таймингов.
# После любой записи программа запоминает, что просили, и после перезагрузки сверяет с тем, что реально работает.
#
# Что проверено на Legion R7000P (10.11.2026):
#   - «Set T*» кладёт число в BIOS как есть, БЕЗ проверки диапазона - проверяет только эта программа;
#   - «Set Mem Clock» принимает МГц (MT/s / 2), «Set FCLK Frequency» - FCLK в МГц;
#   - вернуть Auto одному полю нельзя, есть только «Reset Mem Para» (все тайминги, скорость, FCLK и режим UCLK
#     уходят в Auto), поэтому Auto для части полей = сброс + повторная запись всего, что остаётся ручным.
#
# Файл должен оставаться в UTF-8 с BOM, иначе PowerShell 5.1 испортит русский текст.
param(
    [switch]$SelfCheck,      # напечатать, что найдено, и выйти
    [double]$Scale = 0,      # открыть с этим масштабом (0.75..2.0), не сохраняя его
    [string]$Lang,           # открыть на этом языке (ru / en), не сохраняя его
    [string]$Tab,            # открыть на вкладке mem / set
    [string]$Plan,           # показать команды для "tRAS=74;tRFC=auto;speed=5200;fclk=2000" - без записи
    [string]$Set,            # записать то же самое без окна (с теми же проверками и правами)
    [string]$ForceTier,      # для проверки: verified / experimental / readonly (понизить уровень можно, повысить - нет)
    [switch]$ForceUnknownLayout   # для проверки: вести себя так, будто раскладка настроек BIOS неизвестна
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$root       = Split-Path -Parent $MyInvocation.MyCommand.Path
$logFile    = Join-Path $root 'rampanel.log'
$profDir    = Join-Path $root 'profiles'
$bakDir     = Join-Path $root 'backup'
$setFile    = Join-Path $root 'rampanel.settings.json'
$pendFile   = Join-Path $root 'rampanel.pending.json'
$taskName   = 'RamPanel'
$aodGuid    = '{5ed15dc0-edef-4161-9151-6014c4cc630c}'
$appVersion = '1.2.0'
$scaleSteps = @(0.75, 1.0, 1.25, 1.5, 1.75, 2.0)

# Проверенные устройства. Раскладка - смещения в переменной настроек разгона BIOS.
$Verified = @(
    @{ Model = '83LT'; Bios = 'RLCN31WW'; Cpu = 'Ryzen 9 8945HX'
       Title = 'Lenovo Legion R7000P 16ADR10 (83LT) · BIOS RLCN31WW · AMD Ryzen 9 8945HX'
       Layout = 'AodSetupRpl/428'; FclkMin = 1800; FclkMax = 2400; SpeedMin = 4000; SpeedMax = 6400 }
)
# Известные раскладки: 0x3C флаг скорости (1 = вручную, FF = Auto), 0x3D скорость MT/s (u16),
# 0x3F.. - тайминги по три байта [флаг][значение u16] в порядке $T, 0x94 FCLK МГц (u16, FFFF = Auto), 0x96 режим UCLK.
$Layouts = @{
    'AodSetupRpl/428' = @{ SpeedFlag = 0x3C; Speed = 0x3D; Timings = 0x3F; Count = 25; Fclk = 0x94; Uclk = 0x96 }
}

# Тайминги: имя команды в интерфейсе AMD, поле в ZenStates-Core. Порядок = порядок в раскладке AodSetupRpl.
$T = [ordered]@{
    Tcl      = @{ cmd = 'Set Tcl';      live = 'CL';      label = 'tCL' }
    Trcd     = @{ cmd = 'Set Trcd';     live = 'RCDRD';   label = 'tRCD' }
    Trp      = @{ cmd = 'Set Trp';      live = 'RP';      label = 'tRP' }
    Tras     = @{ cmd = 'Set Tras';     live = 'RAS';     label = 'tRAS' }
    Trc      = @{ cmd = 'Set Trc';      live = 'RC';      label = 'tRC' }
    Twr      = @{ cmd = 'Set Twr';      live = 'WR';      label = 'tWR' }
    Trfc1    = @{ cmd = 'Set Trfc1';    live = 'RFC';     label = 'tRFC' }
    Trfc2    = @{ cmd = 'Set Trfc2';    live = 'RFC2';    label = 'tRFC2' }
    TrfcSb   = @{ cmd = 'Set TrfcSb';   live = 'RFCsb';   label = 'tRFCsb' }
    Trtp     = @{ cmd = 'Set Trtp';     live = 'RTP';     label = 'tRTP' }
    TrrdL    = @{ cmd = 'Set TrrdL';    live = 'RRDL';    label = 'tRRDL' }
    TrrdS    = @{ cmd = 'Set TrrdS';    live = 'RRDS';    label = 'tRRDS' }
    Tfaw     = @{ cmd = 'Set Tfaw';     live = 'FAW';     label = 'tFAW' }
    TwtrL    = @{ cmd = 'Set TwtrL';    live = 'WTRL';    label = 'tWTRL' }
    TwtrS    = @{ cmd = 'Set TwtrS';    live = 'WTRS';    label = 'tWTRS' }
    TrdrdScL = @{ cmd = 'Set TrdrdScL'; live = 'RDRDSCL'; label = 'tRDRDSCL' }
    TrdrdSc  = @{ cmd = 'Set TrdrdSc';  live = 'RDRDSC';  label = 'tRDRDSC' }
    TrdrdSd  = @{ cmd = 'Set TrdrdSd';  live = 'RDRDSD';  label = 'tRDRDSD' }
    TrdrdDd  = @{ cmd = 'Set TrdrdDd';  live = 'RDRDDD';  label = 'tRDRDDD' }
    TwrwrScL = @{ cmd = 'Set TwrwrScL'; live = 'WRWRSCL'; label = 'tWRWRSCL' }
    TwrwrSc  = @{ cmd = 'Set TwrwrSc';  live = 'WRWRSC';  label = 'tWRWRSC' }
    TwrwrSd  = @{ cmd = 'Set TwrwrSd';  live = 'WRWRSD';  label = 'tWRWRSD' }
    TwrwrDd  = @{ cmd = 'Set TwrwrDd';  live = 'WRWRDD';  label = 'tWRWRDD' }
    Twrrd    = @{ cmd = 'Set Twrrd';    live = 'WRRD';    label = 'tWRRD' }
    Trdwr    = @{ cmd = 'Set Trdwr';    live = 'RDWR';    label = 'tRDWR' }
}
$CmdStart = 'Command Buffer Start'; $CmdEnd = 'Command Buffer End'; $CmdReset = 'Reset Mem Para'
$CmdMem = 'Set Mem Clock'; $CmdFclk = 'Set FCLK Frequency'; $CmdUclk = 'Set UCLK DIV1'

# ---------------------------------------------------------------- тексты на двух языках
$Strings = @{
  ru = @{
    tabMem = 'Память'; tabSet = 'Настройки'
    live = 'Сейчас работает:  {0} MT/s   ·   FCLK {1}   ·   UCLK {2}   ·   GDM {3}   ·   {4}   ·   tREFI {5} ({6} нс)'
    on = 'вкл'; off = 'выкл'
    speed = 'Скорость, MT/s'; fclk = 'FCLK, МГц'; speedName = 'Скорость'; mhz = 'МГц'
    hint = 'Всё применяется после перезагрузки. Слишком жёсткие значения могут не дать ноутбуку загрузиться.'
    colTiming = 'Тайминг'; colLive = 'Сейчас'; colStored = 'В BIOS'; colNew = 'Новое'; colRange = 'Диапазон'; step = 'шаг {0}'
    legend = 'жёлтым — правка   ·   синим — ждёт перезагрузки   ·   красным — недопустимо'
    btnApply = 'Применить'; btnApplyRb = 'Применить и перезагрузить'; btnRefresh = 'Обновить'; btnReset = 'Сбросить правки'
    btnAllAuto = 'Всё в Auto'; btnSave = 'Сохранить профиль'; btnLoad = 'Загрузить профиль'; chkStart = 'Открывать при входе в Windows'
    stPending = 'В BIOS лежат значения, которые ещё не работают ({0} шт.) — включатся после перезагрузки.'
    stSame = 'В BIOS сохранено то же, что работает сейчас.'
    stUnknown = 'Что сейчас сохранено в BIOS, на этом устройстве прочитать нельзя: в таблице — то, что работает.'
    stNothing = 'Менять нечего: всё совпадает с сохранённым в BIOS.'
    stWritten = 'Записано в BIOS и проверено. Новые значения включатся после перезагрузки.'
    stWrittenUnverified = 'Записано в BIOS, но проверить запись до перезагрузки нельзя. После перезагрузки RamPanel сверит, что включилось.'
    stRebooting = 'Записано. Перезагрузка через 15 секунд (отмена: shutdown /a).'
    stAllAuto = 'Отмечено Auto для всех таймингов, скорости и FCLK. Нажми «Применить», чтобы записать в BIOS.'
    stSaved = 'Профиль сохранён: {0}'; stLoaded = 'Профиль загружен в окно: {0}. В BIOS он пока не записан.'
    stStartOn = 'Окно будет открываться при входе в Windows.'; stStartOff = 'Автозапуск окна отключён.'
    errEnter = '{0}: впиши число или отметь Auto'; errNotNumber = '{0}: «{1}» не число'
    errRange = 'допустимо {0}..{1}'; errStep = 'шаг {0}, начиная с {1}'
    errPick = '{0}: выбери значение или отметь Auto'
    tipEnter = 'Впиши число или отметь Auto'; tipInt = 'Нужно целое число'
    mbFix = 'Исправь значения'; mbJustReboot = 'Новых значений нет. Просто перезагрузить?'
    mbWriteHead = 'Записать в BIOS:'
    mbTighter = 'Значений жёстче или выше текущих: {0}. Если компьютер с ними не загрузится, понадобится сброс BIOS вручную.'
    mbReset = 'Auto ставится через общий сброс настроек памяти; всё, что остаётся ручным, будет записано заново.'
    mbResetUnknown = 'Auto ставится через общий сброс настроек памяти BIOS. На этом устройстве неизвестно, что ещё входит в сброс: остальные тайминги будут записаны заново значениями из таблицы, а прочие настройки памяти BIOS могут вернуться к заводским.'
    mbExperimental = 'Экспериментальный режим: это устройство не проверено, запись идёт на твой риск.'
    mbRebootAfter = 'После записи компьютер перезагрузится через 15 секунд.'; mbNextReboot = 'Значения включатся после следующей перезагрузки.'
    mbConfirm = 'Подтверждение'; mbWriteErr = 'Ошибка записи'; mbProfileErr = 'Не удалось прочитать профиль: {0}'
    profileFilter = 'Профиль памяти (*.json)|*.json'
    tighter = '   (жёстче, чем работает сейчас)'; higher = '   (выше, чем работает сейчас)'
    wrongHead = 'В BIOS записалось не то, что просили. Не перезагружайся, пока не исправишь:'
    wrongAuto = '{0}: должен быть Auto, а в BIOS {1}'; wrongVal = '{0}: просили {1}, в BIOS {2}'
    wrongByte = 'байт 0x{0:X}: было {1:X2}, стало {2:X2}'; wrongUclk = 'режим UCLK: было {0:X2}, стало {1:X2}'
    wrongNoChange = 'команды приняты, но настройки BIOS не изменились'
    errAod = 'Интерфейс разгона AMD (AMD_ACPI) не найден'
    errLive = 'Не удалось прочитать работающие тайминги: {0}'; errRefused = 'BIOS отклонил команду 0x{0:X} со значением {1}'
    errFatalTitle = 'RamPanel не может работать'
    errFatal = "Не удалось прочитать тайминги памяти.`r`n`r`n{0}`r`n`r`nRamPanel работает только на процессорах AMD Ryzen и только от имени администратора."
    rebootNote = 'RamPanel: новые настройки памяти. Отмена: shutdown /a'
    setLang = 'Язык'; setScale = 'Масштаб'; setScaleHint = 'Ещё можно Ctrl + плюс / минус, Ctrl + 0 — 100 %'
    footer = 'Эту программу написал Claude — ИИ от Anthropic — по инициативе кожаного.'
    setDevice = 'Устройство'; devFound = 'Этот компьютер: {0}'; devMem = 'Память: {0}'
    tierVerified = 'Проверенное устройство — запись разрешена, после записи настройки BIOS сверяются байт в байт.'
    tierExperimental = 'Экспериментальный режим — устройство не проверено. Команды и допустимые значения берутся у самого BIOS. {0}'
    tierExpLayout = 'Формат настроек BIOS знакомый, запись сверяется сразу.'
    tierExpNoLayout = 'Формат настроек BIOS неизвестен: сверка будет только после перезагрузки.'
    tierReadonly = 'Только просмотр: {0}.'
    whyNoAod = 'в BIOS нет интерфейса разгона AMD (производитель его убрал или скрыл)'
    whyNoCmds = 'интерфейс разгона AMD есть, но команд для таймингов в нём нет'
    whyLpddr = 'распаянная память {0} — для неё запись не поддерживается'
    whyNotAmd = 'процессор не AMD'
    whyForced = 'режим выбран вручную'
    verifiedList = 'Проверенные устройства: {0}'
    chkExp = 'Разрешить запись на этом устройстве (на свой риск)'
    expTitle = 'Экспериментальная запись'
    expText = "Это устройство не проверено:`r`n{0}`r`n`r`nЧто может пойти не так:`r`n• значения, которые BIOS считает допустимыми, могут не дать компьютеру загрузиться;`r`n• на многих ноутбуках сброс BIOS возможен только с разборкой корпуса;`r`n• {1}`r`n`r`nМеняй по одному значению маленькими шагами и сохраняй рабочий профиль. Включить запись?"
    expLayoutOk = 'формат настроек BIOS знакомый — запись будет сверяться сразу.'
    expLayoutUnknown = 'формат настроек BIOS неизвестен — проверить запись можно будет только после перезагрузки.'
    roTitle = 'Только просмотр'
    roBlocked = 'Запись отключена: {0}'
    roExpOff = 'Запись выключена: устройство не проверено. Включить её можно на вкладке «Настройки».'
    devVersion = 'RamPanel {0}'
    pendTitle = 'Проверка после перезагрузки'
    pendOk = 'Записанное {0} включилось полностью ({1} знач.).'
    pendAllAuto = 'Записанное {0}: всё в Auto, значения BIOS выбрал сам — сверять нечего.'
    pendBad = "Записанное {0} включилось не полностью:`r`n{1}`r`n`r`nBIOS мог отклонить значения или откатить настройки после неудачного старта."
    pendLine = '{0}: просили {1}, работает {2}'
    unknownVal = '?'
  }
  en = @{
    tabMem = 'Memory'; tabSet = 'Settings'
    live = 'Running now:  {0} MT/s   ·   FCLK {1}   ·   UCLK {2}   ·   GDM {3}   ·   {4}   ·   tREFI {5} ({6} ns)'
    on = 'on'; off = 'off'
    speed = 'Speed, MT/s'; fclk = 'FCLK, MHz'; speedName = 'Speed'; mhz = 'MHz'
    hint = 'Everything applies after a reboot. Values that are too tight may stop the computer from booting.'
    colTiming = 'Timing'; colLive = 'Now'; colStored = 'In BIOS'; colNew = 'New'; colRange = 'Range'; step = 'step {0}'
    legend = 'yellow — edited   ·   blue — waiting for a reboot   ·   red — invalid'
    btnApply = 'Apply'; btnApplyRb = 'Apply and reboot'; btnRefresh = 'Refresh'; btnReset = 'Discard edits'
    btnAllAuto = 'All to Auto'; btnSave = 'Save profile'; btnLoad = 'Load profile'; chkStart = 'Open at Windows sign-in'
    stPending = 'The BIOS holds {0} value(s) that are not running yet — they take effect after a reboot.'
    stSame = 'The BIOS holds the same values that are running now.'
    stUnknown = 'What the BIOS has stored cannot be read on this device: the table shows what is running.'
    stNothing = 'Nothing to change: everything matches the BIOS.'
    stWritten = 'Written to the BIOS and verified. New values take effect after a reboot.'
    stWrittenUnverified = 'Written to the BIOS, but it cannot be verified before a reboot. RamPanel will check what is running after the reboot.'
    stRebooting = 'Written. Rebooting in 15 seconds (cancel: shutdown /a).'
    stAllAuto = 'Auto selected for all timings, speed and FCLK. Press Apply to write it to the BIOS.'
    stSaved = 'Profile saved: {0}'; stLoaded = 'Profile loaded into the window: {0}. Not written to the BIOS yet.'
    stStartOn = 'The window will open at Windows sign-in.'; stStartOff = 'Opening at sign-in is off.'
    errEnter = '{0}: enter a number or tick Auto'; errNotNumber = '{0}: "{1}" is not a number'
    errRange = 'allowed {0}..{1}'; errStep = 'step {0}, starting at {1}'
    errPick = '{0}: pick a value or tick Auto'
    tipEnter = 'Enter a number or tick Auto'; tipInt = 'Whole number required'
    mbFix = 'Fix the values'; mbJustReboot = 'No new values. Just reboot?'
    mbWriteHead = 'Write to the BIOS:'
    mbTighter = '{0} value(s) are tighter or higher than what runs now. If the computer does not boot with them, the BIOS will need a manual reset.'
    mbReset = 'Auto is set through a full memory settings reset; everything that stays manual is written again.'
    mbResetUnknown = 'Auto is set through a full BIOS memory settings reset. On this device it is unknown what else the reset covers: the other timings are written again from the table, other BIOS memory settings may return to factory values.'
    mbExperimental = 'Experimental mode: this device is not verified, writing is at your own risk.'
    mbRebootAfter = 'The computer reboots 15 seconds after writing.'; mbNextReboot = 'The values take effect after the next reboot.'
    mbConfirm = 'Confirm'; mbWriteErr = 'Write error'; mbProfileErr = 'Could not read the profile: {0}'
    profileFilter = 'Memory profile (*.json)|*.json'
    tighter = '   (tighter than what runs now)'; higher = '   (higher than what runs now)'
    wrongHead = 'The BIOS stored something other than requested. Do not reboot until this is fixed:'
    wrongAuto = '{0}: should be Auto, the BIOS has {1}'; wrongVal = '{0}: requested {1}, the BIOS has {2}'
    wrongByte = 'byte 0x{0:X}: was {1:X2}, now {2:X2}'; wrongUclk = 'UCLK mode: was {0:X2}, now {1:X2}'
    wrongNoChange = 'the commands were accepted, but the BIOS settings did not change'
    errAod = 'AMD overclocking interface (AMD_ACPI) not found'
    errLive = 'Could not read the running timings: {0}'; errRefused = 'The BIOS refused command 0x{0:X} with value {1}'
    errFatalTitle = 'RamPanel cannot run'
    errFatal = "Could not read the memory timings.`r`n`r`n{0}`r`n`r`nRamPanel works only on AMD Ryzen processors and only as administrator."
    rebootNote = 'RamPanel: new memory settings. Cancel: shutdown /a'
    setLang = 'Language'; setScale = 'Scale'; setScaleHint = 'Also Ctrl + plus / minus, Ctrl + 0 for 100 %'
    footer = 'This program was written by Claude, an AI by Anthropic, on a fleshy human''s initiative.'
    setDevice = 'Device'; devFound = 'This computer: {0}'; devMem = 'Memory: {0}'
    tierVerified = 'Verified device — writing is allowed, the BIOS settings are checked byte by byte after every write.'
    tierExperimental = 'Experimental mode — this device is not verified. Commands and allowed values come from the BIOS itself. {0}'
    tierExpLayout = 'The BIOS settings format is known, writes are checked right away.'
    tierExpNoLayout = 'The BIOS settings format is unknown: writes are checked only after a reboot.'
    tierReadonly = 'Read-only: {0}.'
    whyNoAod = 'the BIOS has no AMD overclocking interface (the maker removed or hid it)'
    whyNoCmds = 'the AMD overclocking interface exists but has no timing commands'
    whyLpddr = 'soldered {0} memory — writing is not supported for it'
    whyNotAmd = 'not an AMD processor'
    whyForced = 'mode chosen manually'
    verifiedList = 'Verified devices: {0}'
    chkExp = 'Allow writing on this device (at your own risk)'
    expTitle = 'Experimental writing'
    expText = "This device is not verified:`r`n{0}`r`n`r`nWhat can go wrong:`r`n• values the BIOS accepts may still stop the computer from booting;`r`n• on many laptops a BIOS reset needs the case opened;`r`n• {1}`r`n`r`nChange one value at a time in small steps and keep a working profile. Enable writing?"
    expLayoutOk = 'the BIOS settings format is known — writes are checked right away.'
    expLayoutUnknown = 'the BIOS settings format is unknown — writes can be checked only after a reboot.'
    roTitle = 'Read-only'
    roBlocked = 'Writing is off: {0}'
    roExpOff = 'Writing is off: the device is not verified. It can be enabled on the Settings tab.'
    devVersion = 'RamPanel {0}'
    pendTitle = 'Check after reboot'
    pendOk = 'What was written {0} is fully running ({1} value(s)).'
    pendAllAuto = 'Written {0}: everything is Auto, the BIOS chose the values itself — nothing to compare.'
    pendBad = "What was written {0} is not fully running:`r`n{1}`r`n`r`nThe BIOS may have rejected values or rolled the settings back after a failed start."
    pendLine = '{0}: requested {1}, running {2}'
    unknownVal = '?'
  }
}

$settings = @{ scale = 1.0; lang = 'ru'; expDevice = '' }
try {
    if (Test-Path $setFile) {
        $j = Get-Content $setFile -Raw | ConvertFrom-Json
        if ($j.scale) { $settings.scale = [double]$j.scale }
        if ($j.lang -in 'ru', 'en') { $settings.lang = "$($j.lang)" }
        if ($j.expDevice) { $settings.expDevice = "$($j.expDevice)" }
    }
} catch {}
if ($Scale -gt 0) { $settings.scale = $Scale }
if ($Lang -in 'ru', 'en') { $settings.lang = $Lang }
if ($scaleSteps -notcontains $settings.scale) { $settings.scale = 1.0 }

function L([string]$key) {
    $s = $Strings[$settings.lang][$key]
    if ($null -eq $s) { $s = $Strings['ru'][$key] }
    if ($args.Count) { return ($s -f $args) }
    return $s
}
function Save-Settings { try { @{ scale = $settings.scale; lang = $settings.lang; expDevice = $settings.expDevice } | ConvertTo-Json | Set-Content -Path $setFile -Encoding UTF8 } catch {} }
function Log([string]$m) { Add-Content -Path $logFile -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $m) -Encoding UTF8 }

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class RamPanelNative {
    [DllImport("ntdll.dll")] static extern int RtlAdjustPrivilege(int p, bool e, bool t, out bool w);
    [DllImport("ntdll.dll")] static extern int NtEnumerateSystemEnvironmentValuesEx(int cls, IntPtr buf, ref int len);
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern uint GetFirmwareEnvironmentVariableExW(string n, string g, byte[] b, uint s, out uint a);
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);
    [DllImport("uxtheme.dll", CharSet=CharSet.Unicode)] public static extern int SetWindowTheme(IntPtr h, string app, string id);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    // недокументированные функции тёмной темы Windows 10/11 (нужны для тёмных полос прокрутки)
    [DllImport("uxtheme.dll", EntryPoint="#135")] public static extern int SetPreferredAppMode(int mode);
    [DllImport("uxtheme.dll", EntryPoint="#133")] public static extern bool AllowDarkModeForWindow(IntPtr h, bool allow);
    public static void DarkControl(IntPtr h) {
        try { AllowDarkModeForWindow(h, true); } catch {}
        SetWindowTheme(h, "DarkMode_Explorer", null);
    }
    public static byte[] ReadVar(string name, string guid) {
        bool w; RtlAdjustPrivilege(22, true, false, out w);
        byte[] b = new byte[65536]; uint a;
        uint r = GetFirmwareEnvironmentVariableExW(name, guid, b, (uint)b.Length, out a);
        if (r == 0) return null;
        byte[] o = new byte[r]; Array.Copy(b, o, r); return o;
    }
    // Names of every UEFI variable with the given vendor GUID (read-only).
    public static string[] VarNames(string guid) {
        var res = new List<string>();
        bool w; RtlAdjustPrivilege(22, true, false, out w);
        Guid want = new Guid(guid); int len = 0;
        NtEnumerateSystemEnvironmentValuesEx(2, IntPtr.Zero, ref len);
        if (len <= 0) len = 4 * 1024 * 1024;
        IntPtr buf = Marshal.AllocHGlobal(len);
        try {
            if (NtEnumerateSystemEnvironmentValuesEx(2, buf, ref len) != 0) return res.ToArray();
            int off = 0;
            while (true) {
                int next = Marshal.ReadInt32(buf, off);
                byte[] g = new byte[16]; Marshal.Copy(IntPtr.Add(buf, off + 16), g, 0, 16);
                if (new Guid(g) == want) res.Add(Marshal.PtrToStringUni(IntPtr.Add(buf, off + 32)));
                if (next == 0) break;
                off += next;
            }
        } finally { Marshal.FreeHGlobal(buf); }
        return res.ToArray();
    }
    public static void DarkTitle(IntPtr h) { int on = 1; DwmSetWindowAttribute(h, 20, ref on, 4); }
}
'@

# ---------------------------------------------------------------- интерфейс AMD
$script:aod = $null; $script:cmds = @{}
function Get-Aod {
    if (-not $script:aod) { $script:aod = Get-CimInstance -Namespace root\wmi -ClassName AMD_ACPI -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if (-not $script:aod) { throw (L 'errAod') }
    return $script:aod
}
# Список команд, которые BIOS сам объявляет: имя -> ID.
function Get-AodCommands {
    $map = @{}
    foreach ($m in 'GetObjectID', 'GetObjectID2') {
        try {
            $pk = (Invoke-CimMethod -InputObject (Get-Aod) -MethodName $m).pack
            for ($i = 0; $i -lt @($pk.ID).Count; $i++) { $n = "$(@($pk.IDstring)[$i])".Trim(); if ($n) { $map[$n] = [uint32]@($pk.ID)[$i] } }
        } catch {}
    }
    return $map
}
function Get-Cmd([string]$name) { if ($script:cmds.ContainsKey($name)) { return $script:cmds[$name] } else { return $null } }
function Invoke-Aod([uint32]$id, [uint32]$arg) {
    $buf = [byte[]]([BitConverter]::GetBytes($id) + [BitConverter]::GetBytes($arg))
    $r = Invoke-CimMethod -InputObject (Get-Aod) -MethodName RunCommand -Arguments @{ Inbuf = $buf }
    if (-not $r.ReturnValue) { throw (L 'errRefused' $id $arg) }
}
function Get-AodRange([uint32]$id) {
    try { (Invoke-CimMethod -InputObject (Get-Aod) -MethodName GetMinMaxSteppingValues -Arguments @{ ID = $id }).pack } catch { $null }
}
function Get-AodList([uint32]$id) {
    try {
        $dv = (Invoke-CimMethod -InputObject (Get-Aod) -MethodName Getdvalues -Arguments @{ ID = $id }).pack
        return @(@($dv.DValuesBuffer) | Select-Object -First ([int]$dv.Length) | ForEach-Object { [int]$_ } | Where-Object { $_ -gt 0 })
    } catch { return @() }
}

# ---------------------------------------------------------------- переменная настроек разгона в BIOS
# Ищет переменную AodSetup* с GUID интерфейса AMD; раскладка известна только для перечисленных в $Layouts.
function Find-AodVar {
    $names = @()
    try { $names = @([RamPanelNative]::VarNames($aodGuid) | Where-Object { $_ -like 'AodSetup*' }) } catch {}
    if (-not $names.Count) { $names = @('AodSetupRpl', 'AodSetup', 'AodSetupPhx', 'AodSetupStx', 'AodSetupRmb', 'AodSetupMdn') }
    foreach ($n in $names) {
        $b = $null; try { $b = [RamPanelNative]::ReadVar($n, $aodGuid) } catch {}
        if ($b) { return @{ Name = $n; Bytes = $b; Key = "$n/$($b.Length)" } }
    }
    return $null
}
function Read-AodBytes { $b = [RamPanelNative]::ReadVar($script:var.Name, $aodGuid); if (-not $b) { throw "cannot read $($script:var.Name)" }; return , $b }
# Знакомая раскладка + проверка здравого смысла: флаги таймингов 0/1, флаг скорости 1/FF.
function Test-Layout($var) {
    if (-not $var -or -not $Layouts.ContainsKey($var.Key)) { return $null }
    $ly = $Layouts[$var.Key]; $b = $var.Bytes
    for ($i = 0; $i -lt $ly.Count; $i++) { if ($b[$ly.Timings + 3 * $i] -notin 0, 1) { return $null } }
    if ($b[$ly.SpeedFlag] -notin 1, 0xFF) { return $null }
    return $ly
}

# ---------------------------------------------------------------- работающие тайминги
function Get-Live {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'Get-LiveTimings.ps1') 2>&1 }
    finally { $ErrorActionPreference = $old }
    $j = @($o | Where-Object { "$_" -match '^\{' }) | Select-Object -Last 1
    if (-not $j) { throw (L 'errLive' ((@($o | Where-Object { $_ -is [Management.Automation.ErrorRecord] }) | Select-Object -First 1) -replace '\s+', ' ')) }
    return ("$j" | ConvertFrom-Json)
}
function To-IntOrNull($v) { $n = 0; if ([int]::TryParse("$v", [ref]$n)) { return $n } else { return $null } }

# ---------------------------------------------------------------- устройство и уровень поддержки
function Get-Device {
    $pr = Get-CimInstance Win32_ComputerSystemProduct; $bi = Get-CimInstance Win32_BIOS; $cp = Get-CimInstance Win32_Processor | Select-Object -First 1
    $dv = [ordered]@{ Vendor = "$($pr.Vendor)".Trim(); Model = "$($pr.Name)".Trim(); Family = "$($pr.Version)".Trim()
                      Bios = "$($bi.SMBIOSBIOSVersion)".Trim(); Cpu = ("$($cp.Name)" -replace '\s+', ' ').Trim(); CpuVendor = "$($cp.Manufacturer)".Trim() }
    $dv.Text = "$($dv.Vendor) $($dv.Family) ($($dv.Model)) · BIOS $($dv.Bios) · $($dv.Cpu)"
    $dv.Key = "$($dv.Vendor)|$($dv.Model)|$($dv.Bios)"
    $dv.Verified = $Verified | Where-Object { $_.Model -eq $dv.Model -and $_.Bios -eq $dv.Bios -and $dv.Cpu -match [regex]::Escape($_.Cpu) } | Select-Object -First 1
    return $dv
}

function Get-Support {
    $sup = @{ Tier = 'readonly'; Why = ''; Aod = $false; Layout = $null }
    $isAmd = $script:dev.CpuVendor -match 'AMD' -or $script:dev.Cpu -match 'AMD|Ryzen'
    try { [void](Get-Aod); $sup.Aod = $true; $script:cmds = Get-AodCommands } catch {}
    $script:var = $null; try { $script:var = Find-AodVar } catch {}
    $sup.Layout = if ($ForceUnknownLayout) { $null } else { Test-Layout $script:var }
    $timingCmds = @($T.Keys | Where-Object { Get-Cmd $T[$_].cmd }).Count
    $hasBuffer = (Get-Cmd $CmdStart) -and (Get-Cmd $CmdEnd)
    $mem = "$($script:live.Type)"
    if (-not $isAmd) { $sup.Why = L 'whyNotAmd' }
    elseif (-not $sup.Aod) { $sup.Why = L 'whyNoAod' }
    elseif (-not $timingCmds -or -not $hasBuffer) { $sup.Why = L 'whyNoCmds' }
    elseif ($mem -match 'LP') { $sup.Why = L 'whyLpddr' $mem }
    elseif ($script:dev.Verified -and $sup.Layout -and $script:var.Key -eq $script:dev.Verified.Layout) { $sup.Tier = 'verified' }
    else { $sup.Tier = 'experimental' }
    # ручной выбор уровня только понижает
    $rank = @{ readonly = 0; experimental = 1; verified = 2 }
    if ($ForceTier -and $rank.ContainsKey($ForceTier) -and $rank[$ForceTier] -lt $rank[$sup.Tier]) { $sup.Tier = $ForceTier; if (-not $sup.Why) { $sup.Why = L 'whyForced' } }
    return $sup
}
function Test-CanWrite { $script:sup.Tier -eq 'verified' -or ($script:sup.Tier -eq 'experimental' -and $settings.expDevice -eq $script:dev.Key) }

# ---------------------------------------------------------------- всё, что нужно окну
function Get-Data {
    $script:live = Get-Live
    $lv = $script:live
    if ($script:sup -and $script:var) { try { $script:var.Bytes = Read-AodBytes } catch {} }
    $ly = if ($script:sup) { $script:sup.Layout } else { $null }
    $vb = if ($script:var) { $script:var.Bytes } else { $null }
    $rows = @(); $idx = 0
    foreach ($n in $T.Keys) {
        $id = Get-Cmd $T[$n].cmd
        $liveVal = To-IntOrNull $lv.($T[$n].live)
        if ($null -eq $id -and $null -eq $liveVal) { $idx++; continue }
        $rg = if ($null -ne $id) { Get-AodRange $id } else { $null }
        $row = [pscustomobject]@{
            Key = $n; Label = $T[$n].label; Id = $id; Live = $liveVal; Known = [bool]$ly
            Stored = $liveVal; Manual = $true; FromPending = $false
            Min =$(if ($rg) { [int]$rg.Min } else { $null }); Max = $(if ($rg) { [int]$rg.Max } else { $null }); Step = $(if ($rg) { [int]$rg.Stepping } else { 1 })
        }
        if ($ly -and $idx -lt $ly.Count) {
            $row.Stored = [int][BitConverter]::ToUInt16($vb, $ly.Timings + 1 + 3 * $idx); $row.Manual = ($vb[$ly.Timings + 3 * $idx] -eq 1)
        }
        $rows += $row; $idx++
    }
    $vf = $script:dev.Verified
    $speedLive = To-IntOrNull $lv.Frequency; $fclkLive = To-IntOrNull $lv.FCLK
    $d = @{ Rows = $rows; Known = [bool]$ly; Refi = To-IntOrNull $lv.REFI
            SpeedLive = $speedLive; GDM = "$($lv.GDM)"; Cmd2T = "$($lv.Cmd2T)"; MemType = "$($lv.Type)"
            FclkLive = $fclkLive; UclkLive = "$($lv.UCLK)"
            SpeedStored = $speedLive; SpeedManual = $true; FclkRaw = $fclkLive; FclkManual = $true; UclkRaw = 0xFF
            SpeedList = @(); FclkList = @() }
    # режим UCLK, который реально работает: 1 = 1:1 (UCLK = MCLK), 0 = 1:2 (UCLK = MCLK / 2)
    $uL = To-IntOrNull $lv.UCLK; $mL = To-IntOrNull $lv.MCLK
    $d.UclkLiveMode = if ($uL -and $mL) { if ([math]::Abs($uL - $mL) -lt 20) { 1 } elseif ([math]::Abs(2 * $uL - $mL) -lt 40) { 0 } else { $null } } else { $null }
    if ($null -ne $d.UclkLiveMode) { $d.UclkRaw = $d.UclkLiveMode }
    $d.UclkManual = $null -ne $d.UclkLiveMode
    $d.FromPending = $false
    if (-not $ly) {
        # формат настроек BIOS неизвестен: до перезагрузки «в BIOS» = то, что RamPanel сам туда записал
        $pd = Get-PendingState
        if ($pd) {
            $d.FromPending = $true
            foreach ($r in $rows) {
                $w = $pd.timings.($r.Key); if ($null -eq $w) { continue }
                $r.FromPending = $true
                if ("$w" -eq 'auto') { $r.Manual = $false } else { $r.Manual = $true; $r.Stored = [int]$w }
            }
            if ($pd.speed) { if ("$($pd.speed)" -eq 'auto') { $d.SpeedManual = $false } else { $d.SpeedStored = [int]$pd.speed } }
            if ($pd.fclk) { if ("$($pd.fclk)" -eq 'auto') { $d.FclkManual = $false } else { $d.FclkRaw = [int]$pd.fclk } }
            if ($null -ne $pd.uclk) { if ("$($pd.uclk)" -eq 'auto') { $d.UclkManual = $false } else { $d.UclkManual = $true; $d.UclkRaw = [int]$pd.uclk } }
        }
    }
    if ($ly) {
        $d.SpeedStored = [int][BitConverter]::ToUInt16($vb, $ly.Speed); $d.SpeedManual = ($vb[$ly.SpeedFlag] -eq 1)
        $raw = [int][BitConverter]::ToUInt16($vb, $ly.Fclk); $d.FclkRaw = $raw; $d.FclkManual = ($raw -ne 0xFFFF)
        $d.UclkRaw = [int]$vb[$ly.Uclk]; $d.UclkManual = ($d.UclkRaw -ne 0xFF)
    }
    # списки допустимых значений: у проверенных устройств - проверенный коридор, у остальных - около текущего
    $memId = Get-Cmd $CmdMem
    if ($null -ne $memId) {
        $lo = if ($vf) { $vf.SpeedMin } elseif ($speedLive) { [math]::Max(3200, $speedLive * 0.75) } else { 3200 }
        $hi = if ($vf) { $vf.SpeedMax } elseif ($speedLive) { $speedLive * 1.15 } else { 6400 }
        $d.SpeedList = @(Get-AodList $memId | ForEach-Object { $_ * 2 } | Where-Object { $_ -ge $lo -and $_ -le $hi })
        if ($d.SpeedManual -and $d.SpeedStored -and $d.SpeedList -notcontains $d.SpeedStored) { $d.SpeedList = @($d.SpeedList + $d.SpeedStored | Sort-Object -Unique) }
    }
    $fId = Get-Cmd $CmdFclk
    if ($null -ne $fId) {
        $lo = if ($vf) { $vf.FclkMin } elseif ($fclkLive) { $fclkLive * 0.9 } else { 1600 }
        $hi = if ($vf) { $vf.FclkMax } elseif ($fclkLive) { $fclkLive * 1.2 } else { 2400 }
        $d.FclkList = @(Get-AodList $fId | Where-Object { $_ -ge $lo -and $_ -le $hi })
        if ($d.FclkManual -and $d.FclkRaw -and $d.FclkList -notcontains $d.FclkRaw) { $d.FclkList = @($d.FclkList + $d.FclkRaw | Sort-Object -Unique) }
    }
    return $d
}

function Test-Value($row, [int]$value) {
    if ($null -ne $row.Min -and ($value -lt $row.Min -or $value -gt $row.Max)) { return (L 'errRange' $row.Min $row.Max) }
    if ($null -ne $row.Min -and $row.Step -gt 1 -and (($value - $row.Min) % $row.Step) -ne 0) { return (L 'errStep' $row.Step $row.Min) }
    return $null
}

# Сравнивает желаемое с сохранённым (или, если сохранённое неизвестно, с работающим) и решает, какие команды слать.
#   $want: @{ timings = @{ Tcl = 36 | 'auto'; ... }; speed = 5200 | 'auto'; fclk = 2000 | 'auto' }
function Get-ApplyPlan($d, $want) {
    $diff = @(); $tighter = 0; $toAuto = $false
    foreach ($r in $d.Rows) {
        if ($null -eq $r.Id) { continue }
        $w = $want.timings[$r.Key]
        $from = if ($r.Manual) { "$($r.Stored)" } else { 'Auto' }
        if ("$w" -eq 'auto') { if ($r.Manual) { $diff += "$($r.Label): $from → Auto"; $toAuto = $true } }
        elseif (-not $r.Manual -or [int]$w -ne $r.Stored) {
            $mark = ''
            if ($null -ne $r.Live -and [int]$w -lt $r.Live) { $mark = L 'tighter'; $tighter++ }
            $diff += "$($r.Label): $from → $w$mark"
        }
    }
    $speedChanged = $false; $fclkChanged = $false; $uclkChanged = $false
    if (-not $want.ContainsKey('uclk')) { $want.uclk = $(if ($d.UclkManual) { $d.UclkRaw } else { 'auto' }) }
    if ($null -ne (Get-Cmd $CmdMem)) {
        $sFrom = if ($d.SpeedManual) { "$($d.SpeedStored)" } else { 'Auto' }
        if ("$($want.speed)" -eq 'auto') { if ($d.SpeedManual) { $diff += "$(L 'speedName'): $sFrom → Auto"; $toAuto = $true } }
        elseif (-not $d.SpeedManual -or [int]$want.speed -ne $d.SpeedStored) {
            $mark = ''; if ($d.SpeedLive -and [int]$want.speed -gt $d.SpeedLive) { $mark = L 'higher'; $tighter++ }
            $diff += "$(L 'speedName'): $sFrom → $($want.speed) MT/s$mark"; $speedChanged = $true
        }
    }
    if ($null -ne (Get-Cmd $CmdFclk)) {
        $fFrom = if ($d.FclkManual) { "$($d.FclkRaw)" } else { 'Auto' }
        if ("$($want.fclk)" -eq 'auto') { if ($d.FclkManual) { $diff += "FCLK: $fFrom → Auto"; $toAuto = $true } }
        elseif (-not $d.FclkManual -or [int]$want.fclk -ne $d.FclkRaw) {
            $mark = ''; if ($d.FclkLive -and [int]$want.fclk -gt $d.FclkLive) { $mark = L 'higher'; $tighter++ }
            $diff += "FCLK: $fFrom → $($want.fclk) $(L 'mhz')$mark"; $fclkChanged = $true
        }
    }
    if ($null -ne (Get-Cmd $CmdUclk)) {
        $uFrom = if ($d.UclkManual) { Get-UclkText $d.UclkRaw } else { 'Auto' }
        if ("$($want.uclk)" -eq 'auto') { if ($d.UclkManual) { $diff += "UCLK: $uFrom → Auto"; $toAuto = $true } }
        elseif (-not $d.UclkManual -or [int]$want.uclk -ne $d.UclkRaw) {
            $mark = ''; if ([int]$want.uclk -eq 1 -and $d.UclkLiveMode -eq 0) { $mark = L 'higher'; $tighter++ }
            $diff += "UCLK: $uFrom → $(Get-UclkText $want.uclk)$mark"; $uclkChanged = $true
        }
    }
    if ($toAuto -and $null -eq (Get-Cmd $CmdReset)) { throw 'this BIOS has no "Reset Mem Para" command, Auto cannot be set' }
    $sets = @()
    foreach ($r in $d.Rows) {
        if ($null -eq $r.Id) { continue }
        $w = $want.timings[$r.Key]
        if ("$w" -eq 'auto') { continue }
        # после сброса шлём все ручные значения заново, без сброса - только изменившиеся
        if ($toAuto -or -not $r.Manual -or [int]$w -ne $r.Stored) { $sets += @{ id = $r.Id; arg = [int]$w; text = "$($r.Label)=$w" } }
    }
    if ("$($want.speed)" -ne 'auto' -and ($toAuto -or $speedChanged) -and $null -ne (Get-Cmd $CmdMem)) { $sets += @{ id = Get-Cmd $CmdMem; arg = [int]([int]$want.speed / 2); text = "speed=$($want.speed)" } }
    if ("$($want.fclk)" -ne 'auto' -and ($toAuto -or $fclkChanged) -and $null -ne (Get-Cmd $CmdFclk)) { $sets += @{ id = Get-Cmd $CmdFclk; arg = [int]$want.fclk; text = "FCLK=$($want.fclk)" } }
    if ("$($want.uclk)" -ne 'auto' -and ($toAuto -or $uclkChanged) -and $null -ne (Get-Cmd $CmdUclk)) { $sets += @{ id = Get-Cmd $CmdUclk; arg = [int]$want.uclk; text = "UCLK_DIV1=$([int]$want.uclk)" } }
    return @{ reset = $toAuto; sets = $sets; diff = $diff; tighter = $tighter }
}

# Шлёт команды. При знакомой раскладке сверяет настройки BIOS байт в байт, иначе - только что они вообще изменились.
# Возвращает $true, если запись проверена.
function Send-Plan($d, $want, $plan) {
    $before = $null
    if ($script:var) { try { $before = Read-AodBytes } catch {} }
    if ($before) {
        New-Item -ItemType Directory -Force $bakDir | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $bakDir ("{0}_before_{1:yyyyMMdd_HHmmss}.bin" -f $script:var.Name, (Get-Date))), $before)
    }
    if ($plan.reset) { Invoke-Aod (Get-Cmd $CmdStart) 0; Invoke-Aod (Get-Cmd $CmdReset) 0; Invoke-Aod (Get-Cmd $CmdEnd) 0 }
    if ($plan.sets.Count) {
        Invoke-Aod (Get-Cmd $CmdStart) 0
        foreach ($s in $plan.sets) { Invoke-Aod ([uint32]$s.id) ([uint32]$s.arg) }
        Invoke-Aod (Get-Cmd $CmdEnd) 0
    }
    Save-Pending $want
    $after = $null
    if ($before) { try { $after = Read-AodBytes } catch {} }
    $ly = $script:sup.Layout
    $wrong = @(); $verified = $false
    if ($ly -and $after -and $after.Length -eq $before.Length) {
        $areaEnd = $ly.Timings + 3 * $ly.Count - 1
        for ($k = 0; $k -lt $before.Length; $k++) {
            $inside = ($k -ge $ly.SpeedFlag -and $k -le $areaEnd) -or ($k -ge $ly.Fclk -and $k -le $ly.Uclk)
            if (-not $inside -and $before[$k] -ne $after[$k]) { $wrong += (L 'wrongByte' $k $before[$k] $after[$k]) }
        }
        $idx = 0
        foreach ($n in $T.Keys) {
            $r = $d.Rows | Where-Object { $_.Key -eq $n } | Select-Object -First 1
            if ($r -and $null -ne $r.Id) {
                $w = $want.timings[$n]; $flag = $after[$ly.Timings + 3 * $idx]; $val = [int][BitConverter]::ToUInt16($after, $ly.Timings + 1 + 3 * $idx)
                if ("$w" -eq 'auto') { if ($flag -ne 0) { $wrong += (L 'wrongAuto' $r.Label $val) } }
                elseif ($flag -ne 1 -or $val -ne [int]$w) { $wrong += (L 'wrongVal' $r.Label $w $(if ($flag -eq 1) { $val } else { 'Auto' })) }
            }
            $idx++
        }
        if ($null -ne (Get-Cmd $CmdMem)) {
            $sFlag = $after[$ly.SpeedFlag]; $sVal = [int][BitConverter]::ToUInt16($after, $ly.Speed)
            if ("$($want.speed)" -eq 'auto') { if ($sFlag -eq 1) { $wrong += (L 'wrongAuto' (L 'speedName') $sVal) } }
            elseif ($sFlag -ne 1 -or $sVal -ne [int]$want.speed) { $wrong += (L 'wrongVal' (L 'speedName') $want.speed $(if ($sFlag -eq 1) { $sVal } else { 'Auto' })) }
        }
        if ($null -ne (Get-Cmd $CmdFclk)) {
            $fVal = [int][BitConverter]::ToUInt16($after, $ly.Fclk)
            if ("$($want.fclk)" -eq 'auto') { if ($fVal -ne 0xFFFF) { $wrong += (L 'wrongAuto' 'FCLK' $fVal) } }
            elseif ($fVal -ne [int]$want.fclk) { $wrong += (L 'wrongVal' 'FCLK' $want.fclk $(if ($fVal -eq 0xFFFF) { 'Auto' } else { $fVal })) }
        }
        if ($null -ne (Get-Cmd $CmdUclk)) {
            $uVal = [int]$after[$ly.Uclk]
            if ("$($want.uclk)" -eq 'auto') { if ($uVal -ne 0xFF) { $wrong += (L 'wrongAuto' 'UCLK' (Get-UclkText $uVal)) } }
            elseif ($uVal -ne [int]$want.uclk) { $wrong += (L 'wrongVal' 'UCLK' (Get-UclkText $want.uclk) (Get-UclkText $uVal)) }
        }
        $verified = -not $wrong.Count
    } elseif ($before -and $after) {
        $changed = @(0..([math]::Min($before.Length, $after.Length) - 1) | Where-Object { $before[$_] -ne $after[$_] }).Count
        if (($plan.sets.Count -or $plan.reset) -and $changed -eq 0 -and $before.Length -eq $after.Length) { $wrong += (L 'wrongNoChange') }
    }
    Log ("applied [$($script:sup.Tier)$(if (-not $ly) { ', unknown layout' })]: reset=$($plan.reset) " + (($plan.sets | ForEach-Object { $_.text }) -join ' ') +
         $(if ($wrong.Count) { "  MISMATCH: $($wrong -join '; ')" } elseif ($verified) { '  verified' } else { '  not verifiable before reboot' }))
    if ($wrong.Count) { throw ((L 'wrongHead') + "`r`n" + ($wrong -join "`r`n")) }
    return $verified
}

function Get-UclkText($v) { if ("$v" -eq 'auto' -or "$v" -eq '255') { 'Auto' } elseif ([int]$v -eq 1) { '1:1' } else { '1:2' } }

# Что просили - чтобы после перезагрузки сверить с тем, что реально работает.
function Save-Pending($want) {
    try {
        $tm = [ordered]@{}; foreach ($k in $T.Keys) { if ($want.timings.ContainsKey($k)) { $tm[$k] = $want.timings[$k] } }
        [ordered]@{ device = $script:dev.Key; boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o'); time = (Get-Date).ToString('o')
                    speed = $want.speed; fclk = $want.fclk; uclk = $want.uclk; timings = $tm } | ConvertTo-Json | Set-Content -Path $pendFile -Encoding UTF8
    } catch {}
}
# Возвращает @{ ok; text } или $null, если сверять нечего (не было записи или ещё не было перезагрузки).
# Последняя запись, если с тех пор не было перезагрузки (то есть она ещё лежит в BIOS и не работает).
function Get-PendingState {
    if (-not (Test-Path $pendFile)) { return $null }
    try {
        $pd = Get-Content $pendFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($pd.device -ne $script:dev.Key) { return $null }
        if ((Get-CimInstance Win32_OperatingSystem).LastBootUpTime -gt [datetime]$pd.boot) { return $null }
        return $pd
    } catch { return $null }
}
function Test-Pending {
    if (-not (Test-Path $pendFile)) { return $null }
    try {
        $pd = Get-Content $pendFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($pd.device -ne $script:dev.Key) { Remove-Item $pendFile -Force; return $null }
        $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
        if ($boot -le [datetime]$pd.boot) { return $null }
        $lv = $script:live; $bad = @(); $n = 0
        foreach ($k in $T.Keys) {
            $w = $pd.timings.$k
            if ($null -eq $w -or "$w" -eq 'auto') { continue }
            $cur = To-IntOrNull $lv.($T[$k].live); if ($null -eq $cur) { continue }
            $n++; if ($cur -ne [int]$w) { $bad += (L 'pendLine' $T[$k].label $w $cur) }
        }
        if ("$($pd.speed)" -ne 'auto' -and $pd.speed) { $n++; if ((To-IntOrNull $lv.Frequency) -ne [int]$pd.speed) { $bad += (L 'pendLine' (L 'speedName') $pd.speed $lv.Frequency) } }
        if ("$($pd.fclk)" -ne 'auto' -and $pd.fclk -and "$($lv.FCLK)") { $n++; if ([math]::Abs((To-IntOrNull $lv.FCLK) - [int]$pd.fclk) -gt 20) { $bad += (L 'pendLine' 'FCLK' $pd.fclk $lv.FCLK) } }
        if ($null -ne $pd.uclk -and "$($pd.uclk)" -ne 'auto' -and $null -ne $script:data.UclkLiveMode) {
            $n++; if ($script:data.UclkLiveMode -ne [int]$pd.uclk) { $bad += (L 'pendLine' 'UCLK' (Get-UclkText $pd.uclk) (Get-UclkText $script:data.UclkLiveMode)) }
        }
        Remove-Item $pendFile -Force
        $when = ([datetime]$pd.time).ToString('dd.MM HH:mm')
        $res = @{ ok = (-not $bad.Count); text = $(if ($bad.Count) { L 'pendBad' $when ($bad -join "`r`n") } elseif ($n -eq 0) { L 'pendAllAuto' $when } else { L 'pendOk' $when $n }) }
        Log "after-reboot check of the write from ${when}: $(if ($res.ok) { "all $n running" } else { $bad -join '; ' })"
        return $res
    } catch { return $null }
}

# "tRAS=74;tRFC=auto;speed=5200;fclk=2000;all=auto" -> желаемое состояние (остальное - как сейчас)
function ConvertTo-Want($d, [string]$spec) {
    $want = @{ timings = @{}; speed = $(if ($d.SpeedManual) { $d.SpeedStored } else { 'auto' }); fclk = $(if ($d.FclkManual) { $d.FclkRaw } else { 'auto' })
               uclk = $(if ($d.UclkManual) { $d.UclkRaw } else { 'auto' }) }
    foreach ($r in $d.Rows) { $want.timings[$r.Key] = $(if ($r.Manual) { $r.Stored } else { 'auto' }) }
    foreach ($pair in ($spec -split ';' | Where-Object { $_.Trim() })) {
        $kv = $pair.Split('='); $k = $kv[0].Trim(); $val = $kv[1].Trim().ToLower()
        if ($k -eq 'all') { foreach ($r in $d.Rows) { $want.timings[$r.Key] = 'auto' }; $want.speed = 'auto'; $want.fclk = 'auto'; $want.uclk = 'auto'; continue }
        if ($k -eq 'uclk') {
            $want.uclk = switch ($val) { { $_ -in '1:1', '1' } { 1 } { $_ -in '1:2', '0' } { 0 } 'auto' { 'auto' } default { throw "uclk must be 1:1, 1:2 or auto" } }
            continue
        }
        if ($k -eq 'speed') {
            if ($val -ne 'auto' -and $d.SpeedList -notcontains [int]$val) { throw "speed $val not in ($($d.SpeedList -join ', '))" }
            $want.speed = $(if ($val -eq 'auto') { 'auto' } else { [int]$val }); continue
        }
        if ($k -eq 'fclk') {
            if ($val -ne 'auto' -and $d.FclkList -notcontains [int]$val) { throw "FCLK $val not in ($($d.FclkList -join ', '))" }
            $want.fclk = $(if ($val -eq 'auto') { 'auto' } else { [int]$val }); continue
        }
        $row = $d.Rows | Where-Object { $_.Key -eq $k -or $_.Label -eq $k }
        if (-not $row -or $null -eq $row.Id) { throw "unknown or unsupported timing: $k" }
        if ($val -eq 'auto') { $want.timings[$row.Key] = 'auto' }
        else { $err = Test-Value $row ([int]$val); if ($err) { throw "$($row.Label) = ${val}: $err" }; $want.timings[$row.Key] = [int]$val }
    }
    return $want
}

# ---------------------------------------------------------------- старт: устройство, данные, уровень
$script:dev = Get-Device
$script:sup = $null; $script:var = $null
try { $script:live = Get-Live } catch {
    if ($SelfCheck -or $Plan -or $Set) { throw }
    [void][Windows.Forms.MessageBox]::Show((L 'errFatal' $_.Exception.Message), (L 'errFatalTitle'), 'OK', 'Error'); return
}
$script:sup = Get-Support
$script:data = Get-Data
$script:pending = Test-Pending

if ($SelfCheck) {
    $d = $script:data
    "device: $($script:dev.Text)"
    "tier: $($script:sup.Tier)$(if ($script:sup.Why) { " ($($script:sup.Why))" })   can write: $(Test-CanWrite)   AOD var: $(if ($script:var) { $script:var.Key } else { 'none' })   layout known: $([bool]$script:sup.Layout)"
    "commands: $($script:cmds.Count) ($(@($T.Keys | Where-Object { Get-Cmd $T[$_].cmd }).Count) timing)   memory: $($d.MemType)"
    "UCLK mode: live $(if ($null -ne $d.UclkLiveMode) { Get-UclkText $d.UclkLiveMode } else { '?' }), BIOS $(if ($d.UclkManual) { Get-UclkText $d.UclkRaw } else { 'Auto' })"
    "live: $($d.SpeedLive) MT/s, FCLK $($d.FclkLive), UCLK $($d.UclkLive), GDM $($d.GDM), $($d.Cmd2T), tREFI $($d.Refi)"
    "BIOS: speed $(if (-not $d.Known) { '?' } elseif ($d.SpeedManual) { $d.SpeedStored } else { 'Auto' }), FCLK $(if (-not $d.Known) { '?' } elseif ($d.FclkManual) { $d.FclkRaw } else { 'Auto' })"
    "speeds: $($d.SpeedList -join ', ')"
    "FCLK: $($d.FclkList -join ', ')"
    if ($script:pending) { "after-reboot check: $($script:pending.text)" }
    $d.Rows | Format-Table Label, Live, Stored, Manual, Min, Max, Step -AutoSize | Out-String
    return
}
if ($Plan -or $Set) {
    $want = ConvertTo-Want $script:data ($(if ($Set) { $Set } else { $Plan }))
    $pl = Get-ApplyPlan $script:data $want
    'changes:'; if ($pl.diff.Count) { $pl.diff | ForEach-Object { "  $_" } } else { '  none' }
    "reset first: $($pl.reset)"
    'commands: ' + $(if ($pl.sets.Count) { ($pl.sets | ForEach-Object { $_.text }) -join ', ' } else { 'none' })
    if ($Set -and -not (Test-CanWrite)) { throw $(if ($script:sup.Tier -eq 'experimental') { L 'roExpOff' } else { L 'roBlocked' $script:sup.Why }) }
    if ($Set -and ($pl.reset -or $pl.sets.Count)) { $ok = Send-Plan $script:data $want $pl; $(if ($ok) { 'written and verified, active after a reboot' } else { 'written, NOT verifiable before a reboot' }) }
    return
}

# ---------------------------------------------------------------- окно
[void][RamPanelNative]::SetProcessDPIAware()
try { [void][RamPanelNative]::SetPreferredAppMode(2) } catch {}     # 2 = всегда тёмная
[Windows.Forms.Application]::EnableVisualStyles()

# Палитра (тёмная, минималистичная)
function C([string]$hex) { [Drawing.ColorTranslator]::FromHtml($hex) }
$P = @{
    Bg = C '#16181c'; Surface = C '#1d2025'; Raised = C '#262a30'; Hover = C '#2e333a'; Line = C '#2b2f36'
    Text = C '#e7e9ec'; Muted = C '#8b929c'; Accent = C '#4f8cff'; AccentHover = C '#6a9dff'
    ChangedBg = C '#3a311c'; ChangedFg = C '#ffd27a'; BadBg = C '#45232a'; BadFg = C '#ff9b9b'
    PendingBg = C '#1d2e47'; PendingFg = C '#9cc4ff'; OffFg = C '#5c636c'; OkFg = C '#8fd19e'
}

$g0 = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $dpiFactor = $g0.DpiX / 96.0; $g0.Dispose()
$script:eff = $settings.scale * $dpiFactor
function Px([double]$v) { [int][math]::Round($v * $script:eff) }

$script:scaled = New-Object System.Collections.ArrayList     # элементы, у которых при смене масштаба пересчитываются шрифт/размеры
function Track($ctrl, [string]$font, $w = $null, $h = $null) { [void]$script:scaled.Add(@{ c = $ctrl; f = $font; w = $w; h = $h }); return $ctrl }
function New-Font([string]$kind) {
    switch ($kind) {
        'title' { New-Object Drawing.Font('Segoe UI Semibold', [float](Px 18), [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel) }
        'tab'   { New-Object Drawing.Font('Segoe UI Semibold', [float](Px 15), [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel) }
        'bold'  { New-Object Drawing.Font('Segoe UI Semibold', [float](Px 13), [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel) }
        'small' { New-Object Drawing.Font('Segoe UI', [float](Px 12), [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel) }
        'arrow' { New-Object Drawing.Font('Segoe UI', [float](Px 18), [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel) }
        default { New-Object Drawing.Font('Segoe UI', [float](Px 13), [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel) }
    }
}
function Pad([double]$l, [double]$t, [double]$r, [double]$b) { New-Object Windows.Forms.Padding((Px $l), (Px $t), (Px $r), (Px $b)) }

$script:filling = $false
$script:page = if ($Tab -eq 'set') { 'set' } else { 'mem' }

$form = New-Object Windows.Forms.Form
$form.Text = 'RamPanel — ' + $(if ($script:sup.Tier -eq 'verified') { $script:dev.Verified.Title } else { $script:dev.Text })
$icoPath = Join-Path $root 'RamPanel.ico'
if (Test-Path $icoPath) { try { $form.Icon = New-Object Drawing.Icon($icoPath) } catch {} }
$form.AutoScaleMode = 'None'
$form.BackColor = $P.Bg; $form.ForeColor = $P.Text
$form.KeyPreview = $true
$form.Add_HandleCreated({ try { [RamPanelNative]::DarkTitle($form.Handle) } catch {} })

function New-Table([int]$rows) {
    $tb = New-Object Windows.Forms.TableLayoutPanel
    $tb.Dock = 'Fill'; $tb.ColumnCount = 1; $tb.RowCount = $rows; $tb.BackColor = $P.Bg
    $tb.Margin = New-Object Windows.Forms.Padding(0); $tb.Padding = New-Object Windows.Forms.Padding(0)
    [void]$tb.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
    return $tb
}
function Add-Row($tb, $ctrl, [int]$row, [bool]$fill = $false) {
    [void]$tb.RowStyles.Add((New-Object Windows.Forms.RowStyle($(if ($fill) { 'Percent' } else { 'AutoSize' }), 100)))
    $tb.Controls.Add($ctrl, 0, $row)
}
function New-Label([string]$font = 'body', $color = $null) {
    $l = New-Object Windows.Forms.Label
    $l.AutoSize = $true; $l.ForeColor = $(if ($color) { $color } else { $P.Text }); $l.BackColor = [Drawing.Color]::Transparent
    return (Track $l $font)
}
function New-Flow {
    $f = New-Object Windows.Forms.FlowLayoutPanel
    $f.AutoSize = $true; $f.AutoSizeMode = 'GrowAndShrink'; $f.WrapContents = $true; $f.Dock = 'Fill'; $f.BackColor = $P.Bg
    $f.Margin = New-Object Windows.Forms.Padding(0); $f.Padding = New-Object Windows.Forms.Padding(0)
    return $f
}
# Галочка рисуется сама: выключено - пустая рамка, включено - синий квадрат с белой галкой.
# Системная плоская галочка в тёмной теме выглядит одинаково в обоих состояниях.
function Draw-Box($g, [Drawing.Rectangle]$r, [bool]$on, [bool]$hover, [bool]$enabled = $true) {
    # сглаживание включаем только на время рисования галочки: иначе таблица рисует остальные ячейки со швами
    $oldMode = $g.SmoothingMode
    $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    try { Draw-BoxInner $g $r $on $hover $enabled } finally { $g.SmoothingMode = $oldMode }
}
function Draw-BoxInner($g, [Drawing.Rectangle]$r, [bool]$on, [bool]$hover, [bool]$enabled) {
    $rad = [math]::Max(2, (Px 3)); $dd = $rad * 2
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $path.AddArc($r.X, $r.Y, $dd, $dd, 180, 90); $path.AddArc($r.Right - $dd, $r.Y, $dd, $dd, 270, 90)
    $path.AddArc($r.Right - $dd, $r.Bottom - $dd, $dd, $dd, 0, 90); $path.AddArc($r.X, $r.Bottom - $dd, $dd, $dd, 90, 90); $path.CloseFigure()
    if ($on) {
        $fill = if (-not $enabled) { $P.OffFg } elseif ($hover) { $P.AccentHover } else { $P.Accent }
        $br = New-Object Drawing.SolidBrush($fill); $g.FillPath($br, $path); $br.Dispose()
        $pen = New-Object Drawing.Pen([Drawing.Color]::White, [float][math]::Max(1.6, (Px 2)))
        $pen.StartCap = 'Round'; $pen.EndCap = 'Round'; $pen.LineJoin = 'Round'
        $pts = [Drawing.PointF[]]@(
            (New-Object Drawing.PointF(($r.X + $r.Width * 0.24), ($r.Y + $r.Height * 0.52))),
            (New-Object Drawing.PointF(($r.X + $r.Width * 0.43), ($r.Y + $r.Height * 0.71))),
            (New-Object Drawing.PointF(($r.X + $r.Width * 0.77), ($r.Y + $r.Height * 0.31))))
        $g.DrawLines($pen, $pts); $pen.Dispose()
    } else {
        $pc = if (-not $enabled) { $P.OffFg } elseif ($hover) { $P.Text } else { $P.Muted }
        $pen = New-Object Drawing.Pen($pc, [float][math]::Max(1.2, (Px 1.5)))
        $g.DrawPath($pen, $path); $pen.Dispose()
    }
    $path.Dispose()
}
$script:checks = New-Object System.Collections.ArrayList
function New-Check {
    $k = New-Object Windows.Forms.CheckBox
    $k.AutoSize = $false; $k.ForeColor = $P.Text; $k.BackColor = $P.Bg; $k.Cursor = 'Hand'; $k.TabStop = $false
    $k.Tag = @{ hover = $false }
    $k.Add_Paint({ param($s, $e)
        $g = $e.Graphics; $g.Clear($s.BackColor)
        $bs = Px 16; $y = [int](($s.Height - $bs) / 2)
        Draw-Box $g (New-Object Drawing.Rectangle(1, $y, $bs, $bs)) $s.Checked $s.Tag.hover $s.Enabled
        $tr = New-Object Drawing.Rectangle(($bs + (Px 8)), 0, ($s.Width - $bs - (Px 8)), $s.Height)
        [Windows.Forms.TextRenderer]::DrawText($g, $s.Text, $s.Font, $tr, $(if ($s.Enabled) { $s.ForeColor } else { $P.OffFg }), [Windows.Forms.TextFormatFlags]'VerticalCenter,Left,NoPrefix,SingleLine')
    })
    $k.Add_MouseEnter({ param($s, $e) $s.Tag.hover = $true; $s.Invalidate() })
    $k.Add_MouseLeave({ param($s, $e) $s.Tag.hover = $false; $s.Invalidate() })
    $k.Add_CheckedChanged({ param($s, $e) $s.Invalidate() })
    [void]$script:checks.Add($k)
    return (Track $k 'body')
}
function Update-CheckSizes {
    foreach ($k in $script:checks) {
        $sz = [Windows.Forms.TextRenderer]::MeasureText($k.Text, $k.Font)
        $k.Size = New-Object Drawing.Size(((Px 16) + (Px 8) + $sz.Width + (Px 2)), [math]::Max((Px 24), $sz.Height + (Px 4)))
    }
}
function New-Btn([bool]$primary = $false) {
    $b = New-Object Windows.Forms.Button
    $b.AutoSize = $true; $b.AutoSizeMode = 'GrowAndShrink'; $b.FlatStyle = 'Flat'; $b.UseVisualStyleBackColor = $false; $b.Cursor = 'Hand'
    if ($primary) {
        $b.BackColor = $P.Accent; $b.ForeColor = [Drawing.Color]::White
        $b.FlatAppearance.BorderSize = 0; $b.FlatAppearance.MouseOverBackColor = $P.AccentHover; $b.FlatAppearance.MouseDownBackColor = $P.Accent
    } else {
        $b.BackColor = $P.Raised; $b.ForeColor = $P.Text
        $b.FlatAppearance.BorderColor = $P.Line; $b.FlatAppearance.BorderSize = 1
        $b.FlatAppearance.MouseOverBackColor = $P.Hover; $b.FlatAppearance.MouseDownBackColor = $P.Raised
    }
    return (Track $b $(if ($primary) { 'bold' } else { 'body' }))
}
# «Таблетка»: вкладка или выбор языка; активная подсвечена.
function New-Pill([string]$font = 'body') {
    $b = New-Object Windows.Forms.Button
    $b.AutoSize = $true; $b.AutoSizeMode = 'GrowAndShrink'; $b.FlatStyle = 'Flat'; $b.UseVisualStyleBackColor = $false; $b.Cursor = 'Hand'; $b.TabStop = $false
    $b.FlatAppearance.BorderSize = 1; $b.FlatAppearance.MouseOverBackColor = $P.Hover; $b.FlatAppearance.MouseDownBackColor = $P.Raised
    return (Track $b $font)
}
function Set-PillActive($b, [bool]$on) {
    $b.BackColor = if ($on) { $P.Raised } else { $P.Bg }
    $b.ForeColor = if ($on) { $P.Text } else { $P.Muted }
    $b.FlatAppearance.BorderColor = if ($on) { $P.Line } else { $P.Bg }
}

# Переключатель значений «‹ 5200 ›» вместо выпадающего списка: системный ComboBox в тёмную тему не красится.
function New-StepBtn([string]$glyph) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $glyph; $b.FlatStyle = 'Flat'; $b.UseVisualStyleBackColor = $false; $b.TabStop = $false; $b.Cursor = 'Hand'
    $b.FlatAppearance.BorderSize = 0; $b.FlatAppearance.MouseOverBackColor = $P.Hover; $b.FlatAppearance.MouseDownBackColor = $P.Line
    $b.Margin = New-Object Windows.Forms.Padding(0); $b.Padding = New-Object Windows.Forms.Padding(0)
    return (Track $b 'arrow' 28 30)
}
function New-Stepper([int]$valueWidth) {
    $f = New-Object Windows.Forms.FlowLayoutPanel
    $f.AutoSize = $true; $f.AutoSizeMode = 'GrowAndShrink'; $f.WrapContents = $false; $f.Padding = New-Object Windows.Forms.Padding(0)
    $prev = New-StepBtn '‹'; $next = New-StepBtn '›'
    $lb = New-Object Windows.Forms.Label
    $lb.AutoSize = $false; $lb.TextAlign = 'MiddleCenter'; $lb.Margin = New-Object Windows.Forms.Padding(0)
    [void](Track $lb 'bold' $valueWidth 30)
    $f.Controls.AddRange(@($prev, $lb, $next))
    $f.Tag = @{ items = @(); index = -1; label = $lb; prev = $prev; next = $next; enabled = $true; onChange = $null }
    $prev.Tag = $f; $next.Tag = $f
    $prev.Add_Click({ param($s, $e) Move-Stepper $s.Tag -1 })
    $next.Add_Click({ param($s, $e) Move-Stepper $s.Tag 1 })
    Update-Stepper $f
    return $f
}
function Update-Stepper($f) {
    $st = $f.Tag
    $st.label.Text = if ($st.index -ge 0) { "$($st.items[$st.index])" } else { '—' }
    $bg = if ($st.enabled) { $P.Raised } else { $P.Bg }
    foreach ($c in @($f, $st.label, $st.prev, $st.next)) { $c.BackColor = $bg }
    $st.label.ForeColor = if ($st.enabled) { $P.Text } else { $P.OffFg }
    $st.prev.ForeColor = if ($st.enabled -and $st.index -gt 0) { $P.Text } else { $P.OffFg }
    $st.next.ForeColor = if ($st.enabled -and $st.index -lt $st.items.Count - 1) { $P.Text } else { $P.OffFg }
    $st.prev.Enabled = $st.enabled; $st.next.Enabled = $st.enabled
}
function Move-Stepper($f, [int]$delta) {
    $st = $f.Tag
    if (-not $st.enabled -or $st.items.Count -eq 0) { return }
    $n = [math]::Max(0, [math]::Min($st.items.Count - 1, $st.index + $delta))
    if ($n -ne $st.index) { $st.index = $n; Update-Stepper $f; if ($st.onChange) { & $st.onChange } }
}
function Set-StepperItems($f, $items, $selected) {
    $st = $f.Tag; $st.items = @($items | ForEach-Object { "$_" })
    $st.index = [array]::IndexOf($st.items, "$selected")
    if ($st.index -lt 0 -and $st.items.Count) { $st.index = 0 }
    Update-Stepper $f
}
function Select-Stepper($f, $value) { $i = [array]::IndexOf($f.Tag.items, "$value"); if ($i -ge 0) { $f.Tag.index = $i }; Update-Stepper $f }
function Get-StepperValue($f) { if ($f.Tag.index -ge 0) { $f.Tag.items[$f.Tag.index] } else { $null } }
function Set-StepperEnabled($f, [bool]$on) { $f.Tag.enabled = $on; Update-Stepper $f }

# ---------------------------------------------------------------- разметка
$rootTbl = New-Table 2
$form.Controls.Add($rootTbl)

$tabs = New-Flow; $tabs.WrapContents = $false
$tabMem = New-Pill 'tab'; $tabSet = New-Pill 'tab'
$tabs.Controls.AddRange(@($tabMem, $tabSet))
Add-Row $rootTbl $tabs 0

$pages = New-Object Windows.Forms.Panel
$pages.Dock = 'Fill'; $pages.BackColor = $P.Bg; $pages.Margin = New-Object Windows.Forms.Padding(0)
Add-Row $rootTbl $pages 1 $true

# --- вкладка «Память»
$pgMem = New-Table 6
$lblLive = New-Label 'small' $P.Muted
Add-Row $pgMem $lblLive 0

$top = New-Flow
$lblSpeed = New-Label 'body' $P.Muted
$cmbSpeed = New-Stepper 60
$chkSpeedAuto = New-Check; $chkSpeedAuto.Text = 'Auto'
$sep = New-Label 'body'
$lblFclk = New-Label 'body' $P.Muted
$cmbFclk = New-Stepper 60
$chkFclkAuto = New-Check; $chkFclkAuto.Text = 'Auto'
# режим UCLK: 1:1 / 1:2 / Auto - три «таблетки», выбранная подсвечена
$sep2 = New-Label 'body'
$lblUclk = New-Label 'body' $P.Muted; $lblUclk.Text = 'UCLK'
$pillU1 = New-Pill; $pillU1.Text = '1:1'; $pillU1.Tag = '1'
$pillU2 = New-Pill; $pillU2.Text = '1:2'; $pillU2.Tag = '0'
$pillUA = New-Pill; $pillUA.Text = 'Auto'; $pillUA.Tag = 'auto'
$script:uclkSel = 'auto'
# каждая настройка - своя группа, чтобы при узком окне подпись не отрывалась от своих кнопок
function New-Group($items) {
    $gr = New-Flow; $gr.WrapContents = $false; $gr.Dock = 'None'
    $gr.Controls.AddRange(@($items)); return $gr
}
$grpSpeed = New-Group @($lblSpeed, $cmbSpeed, $chkSpeedAuto)
$grpFclk  = New-Group @($lblFclk, $cmbFclk, $chkFclkAuto)
$grpUclk  = New-Group @($lblUclk, $pillU1, $pillU2, $pillUA)
$top.Controls.AddRange(@($grpSpeed, $grpFclk, $grpUclk))
Add-Row $pgMem $top 1

$lblHint = New-Label 'small' $P.Muted
Add-Row $pgMem $lblHint 2

$grid = New-Object Windows.Forms.DataGridView
$grid.Dock = 'Fill'
$grid.AllowUserToAddRows = $false; $grid.AllowUserToDeleteRows = $false; $grid.AllowUserToResizeRows = $false; $grid.AllowUserToResizeColumns = $false
$grid.RowHeadersVisible = $false; $grid.SelectionMode = 'CellSelect'; $grid.MultiSelect = $false
$grid.AutoSizeColumnsMode = 'Fill'; $grid.EditMode = 'EditOnEnter'
$grid.BorderStyle = 'None'; $grid.CellBorderStyle = 'SingleHorizontal'; $grid.GridColor = $P.Line
$grid.BackgroundColor = $P.Surface; $grid.EnableHeadersVisualStyles = $false
$grid.ColumnHeadersBorderStyle = 'None'; $grid.ColumnHeadersHeightSizeMode = 'DisableResizing'
$grid.ColumnHeadersDefaultCellStyle.BackColor = $P.Surface; $grid.ColumnHeadersDefaultCellStyle.ForeColor = $P.Muted
$grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = $P.Surface; $grid.ColumnHeadersDefaultCellStyle.SelectionForeColor = $P.Muted
$grid.DefaultCellStyle.BackColor = $P.Surface; $grid.DefaultCellStyle.ForeColor = $P.Text
$grid.DefaultCellStyle.SelectionBackColor = $P.Hover; $grid.DefaultCellStyle.SelectionForeColor = $P.Text
foreach ($c in @(@('Label', 24, $true), @('Live', 14, $true), @('Stored', 15, $true), @('New', 16, $false))) {
    $col = New-Object Windows.Forms.DataGridViewTextBoxColumn
    $col.Name = $c[0]; $col.FillWeight = $c[1]; $col.ReadOnly = $c[2]; $col.SortMode = 'NotSortable'
    [void]$grid.Columns.Add($col)
}
$colAuto = New-Object Windows.Forms.DataGridViewCheckBoxColumn
$colAuto.Name = 'Auto'; $colAuto.HeaderText = 'Auto'; $colAuto.FillWeight = 9; $colAuto.SortMode = 'NotSortable'; $colAuto.FlatStyle = 'Flat'
[void]$grid.Columns.Add($colAuto)
$colRange = New-Object Windows.Forms.DataGridViewTextBoxColumn
$colRange.Name = 'Range'; $colRange.FillWeight = 24; $colRange.ReadOnly = $true; $colRange.SortMode = 'NotSortable'
[void]$grid.Columns.Add($colRange)
foreach ($n in 'Live', 'Range') { $grid.Columns[$n].DefaultCellStyle.ForeColor = $P.Muted }
$gridHost = New-Object Windows.Forms.Panel
$gridHost.Dock = 'Fill'; $gridHost.BackColor = $P.Surface; $gridHost.Margin = New-Object Windows.Forms.Padding(0)
$gridHost.Controls.Add($grid)
Add-Row $pgMem $gridHost 3 $true

$statusBox = New-Table 2
$status = New-Label 'body'
$legend = New-Label 'small' $P.Muted
Add-Row $statusBox $status 0; Add-Row $statusBox $legend 1
$statusBox.AutoSize = $true
Add-Row $pgMem $statusBox 4

$btns = New-Flow
$btnApply = New-Btn $true; $btnApplyRb = New-Btn; $btnRefresh = New-Btn; $btnReset = New-Btn
$btnAllAuto = New-Btn; $btnSave = New-Btn; $btnLoad = New-Btn
$chkStart = New-Check; $chkStart.ForeColor = $P.Muted
$chkStart.Checked = [bool](Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)
$btns.Controls.AddRange(@($btnApply, $btnApplyRb, $btnRefresh, $btnReset, $btnAllAuto, $btnSave, $btnLoad, $chkStart))
Add-Row $pgMem $btns 5

# --- вкладка «Настройки»
$pgSet = New-Table 10
$lblLangTitle = New-Label 'bold'
Add-Row $pgSet $lblLangTitle 0
$langFlow = New-Flow; $langFlow.WrapContents = $false
$pillRu = New-Pill; $pillRu.Text = 'Русский'
$pillEn = New-Pill; $pillEn.Text = 'English'
$langFlow.Controls.AddRange(@($pillRu, $pillEn))
Add-Row $pgSet $langFlow 1
$lblScaleTitle = New-Label 'bold'
Add-Row $pgSet $lblScaleTitle 2
$cmbScale = New-Stepper 64
Set-StepperItems $cmbScale @($scaleSteps | ForEach-Object { "{0}%" -f [int]($_ * 100) }) ("{0}%" -f [int]($settings.scale * 100))
Add-Row $pgSet $cmbScale 3
$lblScaleHint = New-Label 'small' $P.Muted
Add-Row $pgSet $lblScaleHint 4
$lblDevTitle = New-Label 'bold'
Add-Row $pgSet $lblDevTitle 5
$lblDev = New-Label 'small' $P.Muted
Add-Row $pgSet $lblDev 6
$chkExp = New-Check; $chkExp.ForeColor = $P.ChangedFg
Add-Row $pgSet $chkExp 7
$filler = New-Object Windows.Forms.Panel; $filler.Dock = 'Fill'; $filler.BackColor = $P.Bg; $filler.Margin = New-Object Windows.Forms.Padding(0)
Add-Row $pgSet $filler 8 $true
$footBox = New-Table 2
$footLine = New-Object Windows.Forms.Panel; $footLine.Dock = 'Fill'; $footLine.BackColor = $P.Line; $footLine.Height = 1
$lblFooter = New-Label 'small' $P.Muted
Add-Row $footBox $footLine 0; Add-Row $footBox $lblFooter 1
$footBox.AutoSize = $true
Add-Row $pgSet $footBox 9

$pages.Controls.Add($pgMem); $pages.Controls.Add($pgSet)

function Show-Page([string]$name) {
    $script:page = $name
    $pgMem.Visible = ($name -eq 'mem'); $pgSet.Visible = ($name -eq 'set')
    Set-PillActive $tabMem ($name -eq 'mem'); Set-PillActive $tabSet ($name -eq 'set')
}

# ---------------------------------------------------------------- масштаб и язык
function Apply-Scale {
    $form.SuspendLayout()
    try {
        foreach ($it in $script:scaled) {
            $it.c.Font = New-Font $it.f
            if ($it.w) { $it.c.Width = Px $it.w }
            if ($it.h) { $it.c.Height = Px $it.h }
        }
        $rootTbl.Padding = Pad 20 14 20 14
        $tabs.Margin = Pad 0 0 0 14
        foreach ($b in @($tabMem, $tabSet, $pillRu, $pillEn)) { $b.Padding = Pad 12 3 12 3; $b.Margin = Pad 0 0 6 0; $b.MinimumSize = New-Object Drawing.Size(0, (Px 32)) }
        $lblLive.Margin = Pad 0 0 0 12
        $top.Margin = Pad 0 0 0 8
        foreach ($c in @($lblSpeed, $lblFclk)) { $c.Margin = Pad 0 5 8 4 }
        foreach ($c in @($cmbSpeed, $cmbFclk)) { $c.Margin = Pad 0 0 10 4 }
        foreach ($c in @($chkSpeedAuto, $chkFclkAuto)) { $c.Margin = Pad 0 4 8 4 }
        $lblUclk.Margin = Pad 0 5 8 4
        foreach ($b in @($pillU1, $pillU2, $pillUA)) { $b.Padding = Pad 8 2 8 2; $b.Margin = Pad 0 0 4 4; $b.MinimumSize = New-Object Drawing.Size(0, (Px 30)) }
        foreach ($gr in @($grpSpeed, $grpFclk, $grpUclk)) { $gr.Margin = Pad 0 0 20 0 }
        $lblHint.Margin = Pad 0 0 0 10
        $gridHost.Padding = Pad 8 4 8 4
        $grid.DefaultCellStyle.Font = New-Font 'body'
        $grid.ColumnHeadersDefaultCellStyle.Font = New-Font 'small'
        $grid.Columns['New'].DefaultCellStyle.Font = New-Font 'bold'
        $grid.DefaultCellStyle.Padding = Pad 6 0 6 0
        $grid.ColumnHeadersDefaultCellStyle.Padding = Pad 6 0 6 0
        $grid.ColumnHeadersHeight = Px 32
        $grid.RowTemplate.Height = Px 28
        foreach ($r in $grid.Rows) { $r.Height = Px 28 }
        $statusBox.Margin = Pad 0 10 0 8
        $status.Margin = Pad 0 0 0 2
        foreach ($b in $btns.Controls) {
            $b.Margin = Pad 0 0 8 8
            if ($b -is [Windows.Forms.Button]) { $b.Padding = Pad 10 4 10 4; $b.MinimumSize = New-Object Drawing.Size(0, (Px 32)) }
        }
        $chkStart.Margin = Pad 4 8 0 8
        $lblLangTitle.Margin = Pad 0 4 0 8
        $langFlow.Margin = Pad 0 0 0 22
        $lblScaleTitle.Margin = Pad 0 0 0 8
        $cmbScale.Margin = Pad 0 0 0 6
        $lblScaleHint.Margin = Pad 0 0 0 22
        $lblDevTitle.Margin = Pad 0 0 0 8
        $lblDev.Margin = Pad 0 0 0 8
        $chkExp.Margin = Pad 0 4 0 0
        $footBox.Margin = Pad 0 0 0 0
        $footLine.Margin = Pad 0 0 0 10; $footLine.Height = [math]::Max(1, (Px 1))
        $lblFooter.Margin = Pad 0 0 0 2
        Select-Stepper $cmbScale ("{0}%" -f [int]($settings.scale * 100))
        Update-WrapWidths
        $wa = [Windows.Forms.Screen]::FromControl($form).WorkingArea
        $form.MinimumSize = New-Object Drawing.Size([math]::Min((Px 560), $wa.Width), [math]::Min((Px 560), $wa.Height))
    } finally { $form.ResumeLayout($true) }
}
function Update-WrapWidths {
    Update-CheckSizes
    $w = [math]::Max(200, $form.ClientSize.Width - (Px 44))
    foreach ($l in @($status, $lblHint, $lblFooter, $lblLive, $lblDev)) { $l.MaximumSize = New-Object Drawing.Size($w, 0) }
}

function Set-Scale([double]$s, [bool]$save = $true) {
    if ($scaleSteps -notcontains $s) { return }
    $settings.scale = $s; $script:eff = $s * $dpiFactor
    Apply-Scale
    $wa = [Windows.Forms.Screen]::FromControl($form).WorkingArea
    $w = [math]::Min((Px 760), $wa.Width - 20); $h = [math]::Min((Px 1150), $wa.Height - 20)
    $form.Size = New-Object Drawing.Size($w, $h)
    $x = [math]::Max($wa.Left, [math]::Min($form.Left, $wa.Right - $w)); $y = [math]::Max($wa.Top, [math]::Min($form.Top, $wa.Bottom - $h))
    $form.Location = New-Object Drawing.Point($x, $y)
    Update-WrapWidths
    if ($save) { Save-Settings }
}

function Get-TierText {
    switch ($script:sup.Tier) {
        'verified'     { L 'tierVerified' }
        'experimental' { L 'tierExperimental' $(if ($script:sup.Layout) { L 'tierExpLayout' } else { L 'tierExpNoLayout' }) }
        default        { L 'tierReadonly' $script:sup.Why }
    }
}
function Apply-Language {
    $tabMem.Text = L 'tabMem'; $tabSet.Text = L 'tabSet'
    $lblSpeed.Text = L 'speed'; $lblFclk.Text = L 'fclk'; $lblHint.Text = L 'hint'
    $grid.Columns['Label'].HeaderText = L 'colTiming'; $grid.Columns['Live'].HeaderText = L 'colLive'
    $grid.Columns['Stored'].HeaderText = L 'colStored'; $grid.Columns['New'].HeaderText = L 'colNew'
    $grid.Columns['Range'].HeaderText = L 'colRange'
    $legend.Text = L 'legend'
    $btnApply.Text = L 'btnApply'; $btnApplyRb.Text = L 'btnApplyRb'; $btnRefresh.Text = L 'btnRefresh'; $btnReset.Text = L 'btnReset'
    $btnAllAuto.Text = L 'btnAllAuto'; $btnSave.Text = L 'btnSave'; $btnLoad.Text = L 'btnLoad'; $chkStart.Text = L 'chkStart'
    $lblLangTitle.Text = L 'setLang'; $lblScaleTitle.Text = L 'setScale'; $lblScaleHint.Text = L 'setScaleHint'; $lblFooter.Text = L 'footer'
    $lblDevTitle.Text = L 'setDevice'
    $lblDev.Text = (L 'devFound' $script:dev.Text) + "`r`n" + (L 'devMem' "$($script:data.MemType) · $($script:data.SpeedLive) MT/s") + "`r`n`r`n" +
        (Get-TierText) + "`r`n`r`n" + (L 'verifiedList' (($Verified | ForEach-Object { $_.Title }) -join '; ')) + "`r`n" + (L 'devVersion' $appVersion)
    $lblDev.ForeColor = switch ($script:sup.Tier) { 'verified' { $P.Muted } 'experimental' { $P.ChangedFg } default { $P.BadFg } }
    $chkExp.Text = L 'chkExp'
    Set-PillActive $pillRu ($settings.lang -eq 'ru'); Set-PillActive $pillEn ($settings.lang -eq 'en')
    Update-CheckSizes
}

function Set-Language([string]$lang) {
    if ($lang -eq $settings.lang) { return }
    $grid.EndEdit() | Out-Null
    $settings.lang = $lang; Save-Settings
    Apply-Language
    for ($i = 0; $i -lt $grid.Rows.Count; $i++) { $grid.Rows[$i].Cells['Range'].Value = Get-RangeText $script:data.Rows[$i]; Update-RowStyle $i }
    Update-LiveLine; Update-Status
}

# ---------------------------------------------------------------- данные в окне
function Set-CellLook($cell, $bg, $fg) {
    $cell.Style.BackColor = $bg; $cell.Style.ForeColor = $fg
    $cell.Style.SelectionBackColor = $(if ($bg -eq [Drawing.Color]::Empty) { [Drawing.Color]::Empty } else { $bg })
    $cell.Style.SelectionForeColor = $fg
}
function Get-RangeText($r) {
    if ($null -eq $r.Min) { return '—' }
    "$($r.Min)–$($r.Max)" + $(if ($r.Step -gt 1) { ', ' + (L 'step' $r.Step) } else { '' })
}
function Test-RowEditable($r) { (Test-CanWrite) -and $null -ne $r.Id }

# Раскрашивает строку: синим - в BIOS лежит не то, что работает; жёлтым - правка; красным - недопустимое.
function Update-RowStyle([int]$i) {
    $r = $script:data.Rows[$i]; $row = $grid.Rows[$i]
    if (($r.Known -or $r.FromPending) -and $r.Manual -and $r.Stored -ne $r.Live) { Set-CellLook $row.Cells['Stored'] $P.PendingBg $P.PendingFg } else { Set-CellLook $row.Cells['Stored'] ([Drawing.Color]::Empty) ([Drawing.Color]::Empty) }
    $cell = $row.Cells['New']; $auto = [bool]$row.Cells['Auto'].Value
    $cell.ToolTipText = ''
    if (-not (Test-RowEditable $r)) { $cell.ReadOnly = $true; $row.Cells['Auto'].ReadOnly = $true; Set-CellLook $cell ([Drawing.Color]::Empty) $P.OffFg; return }
    $row.Cells['Auto'].ReadOnly = $false
    if ($auto -and $r.Manual) { Set-CellLook $row.Cells['Auto'] $P.ChangedBg $P.ChangedFg } else { Set-CellLook $row.Cells['Auto'] ([Drawing.Color]::Empty) ([Drawing.Color]::Empty) }
    if ($auto) { $cell.ReadOnly = $true; Set-CellLook $cell ([Drawing.Color]::Empty) $P.OffFg; return }
    $cell.ReadOnly = $false
    $txt = "$($cell.Value)".Trim(); $v = 0
    if ($txt -eq '') { Set-CellLook $cell $P.BadBg $P.BadFg; $cell.ToolTipText = L 'tipEnter'; return }
    if (-not [int]::TryParse($txt, [ref]$v)) { Set-CellLook $cell $P.BadBg $P.BadFg; $cell.ToolTipText = L 'tipInt'; return }
    $err = Test-Value $r $v
    if ($err) { Set-CellLook $cell $P.BadBg $P.BadFg; $cell.ToolTipText = $err; return }
    if (-not $r.Manual -or $v -ne $r.Stored) { Set-CellLook $cell $P.ChangedBg $P.ChangedFg } else { Set-CellLook $cell ([Drawing.Color]::Empty) ([Drawing.Color]::Empty) }
}

function Update-TopLook {
    $d = $script:data; $cw = Test-CanWrite
    $hasMem = $null -ne (Get-Cmd $CmdMem) -and $d.SpeedList.Count; $hasF = $null -ne (Get-Cmd $CmdFclk) -and $d.FclkList.Count
    $chkSpeedAuto.Enabled = $cw -and $hasMem; $chkFclkAuto.Enabled = $cw -and $hasF
    Set-StepperEnabled $cmbSpeed ($cw -and $hasMem -and -not $chkSpeedAuto.Checked); Set-StepperEnabled $cmbFclk ($cw -and $hasF -and -not $chkFclkAuto.Checked)
    $sChanged = $hasMem -and $(if ($chkSpeedAuto.Checked) { $d.SpeedManual } else { (-not $d.SpeedManual) -or ("$(Get-StepperValue $cmbSpeed)" -ne "$($d.SpeedStored)") })
    $fChanged = $hasF -and $(if ($chkFclkAuto.Checked) { $d.FclkManual } else { (-not $d.FclkManual) -or ("$(Get-StepperValue $cmbFclk)" -ne "$($d.FclkRaw)") })
    $lblSpeed.ForeColor = if ($sChanged) { $P.ChangedFg } else { $P.Muted }
    $lblFclk.ForeColor  = if ($fChanged) { $P.ChangedFg } else { $P.Muted }
    $hasU = $null -ne (Get-Cmd $CmdUclk)
    $storedSel = if ($d.UclkManual) { "$($d.UclkRaw)" } else { 'auto' }
    foreach ($b in @($pillU1, $pillU2, $pillUA)) {
        $b.Enabled = $cw -and $hasU
        Set-PillActive $b ($script:uclkSel -eq $b.Tag)
        if (-not $b.Enabled -and $script:uclkSel -ne $b.Tag) { $b.ForeColor = $P.OffFg }
    }
    $lblUclk.ForeColor = if ($hasU -and $script:uclkSel -ne $storedSel) { $P.ChangedFg } else { $P.Muted }
}

function Update-LiveLine {
    $d = $script:data
    $refiNs = if ($d.SpeedLive -and $d.Refi) { [math]::Round($d.Refi / ($d.SpeedLive / 2000.0)) } else { '?' }
    $lblLive.Text = L 'live' $d.SpeedLive $(if ($d.FclkLive) { $d.FclkLive } else { '?' }) $(if ($d.UclkLive) { "$($d.UclkLive)$(if ($null -ne $d.UclkLiveMode) { ' (' + (Get-UclkText $d.UclkLiveMode) + ')' })" } else { '?' }) $(if ($d.GDM -eq 'Enabled') { L 'on' } else { L 'off' }) $d.Cmd2T $d.Refi $refiNs
}
function Update-Status {
    $d = $script:data
    if (-not (Test-CanWrite)) {
        $status.ForeColor = if ($script:sup.Tier -eq 'experimental') { $P.ChangedFg } else { $P.BadFg }
        $status.Text = $(if ($script:sup.Tier -eq 'experimental') { L 'roExpOff' } else { L 'roBlocked' $script:sup.Why })
        return
    }
    if (-not $d.Known -and -not $d.FromPending) { $status.ForeColor = $P.Muted; $status.Text = L 'stUnknown'; return }
    $pending = @($d.Rows | Where-Object { $_.Manual -and $_.Stored -ne $_.Live }).Count
    if ($d.SpeedManual -and $d.SpeedStored -ne $d.SpeedLive) { $pending++ }
    if ($d.FclkManual -and $d.FclkLive -and $d.FclkRaw -ne $d.FclkLive) { $pending++ }
    $status.ForeColor = if ($pending) { $P.PendingFg } else { $P.Muted }
    $status.Text = if ($pending) { L 'stPending' $pending } else { L 'stSame' }
}

function Update-WriteControls {
    $cw = Test-CanWrite
    foreach ($b in @($btnApply, $btnApplyRb, $btnAllAuto)) {
        $b.Enabled = $cw
        if ($cw) { $b.BackColor = $(if ($b -eq $btnApply) { $P.Accent } else { $P.Raised }); $b.ForeColor = $(if ($b -eq $btnApply) { [Drawing.Color]::White } else { $P.Text }) }
        else { $b.BackColor = $P.Surface; $b.ForeColor = $P.OffFg }
    }
    $btnLoad.Enabled = $cw
    $chkExp.Visible = $script:sup.Tier -eq 'experimental'
    $script:filling = $true; try { $chkExp.Checked = ($settings.expDevice -eq $script:dev.Key) } finally { $script:filling = $false }
}

function Fill-Form {
    $d = $script:data
    $script:filling = $true
    try {
        $grid.Rows.Clear()
        $u = L 'unknownVal'
        foreach ($r in $d.Rows) {
            $seen = $r.Known -or $r.FromPending
            $stored = if (-not $seen) { $u } elseif ($r.Manual) { "$($r.Stored)" } else { 'Auto' }
            $new = if ($seen -and -not $r.Manual) { '' } elseif ($null -ne $r.Stored) { "$($r.Stored)" } else { '' }
            [void]$grid.Rows.Add($r.Label, $(if ($null -ne $r.Live) { "$($r.Live)" } else { '—' }), $stored, $new, ($seen -and -not $r.Manual), (Get-RangeText $r))
        }
        foreach ($r in $grid.Rows) { $r.Height = Px 28 }
        if ($d.SpeedList.Count) { Set-StepperItems $cmbSpeed $d.SpeedList $(if ($d.SpeedManual) { $d.SpeedStored } else { $d.SpeedLive }) } else { Set-StepperItems $cmbSpeed @("$($d.SpeedLive)") $d.SpeedLive }
        $chkSpeedAuto.Checked = -not $d.SpeedManual
        if ($d.FclkList.Count) {
            $fSel = if ($d.FclkManual -and $d.FclkRaw) { $d.FclkRaw } elseif ($d.FclkList -contains $d.FclkLive) { $d.FclkLive } else { $d.FclkList[0] }
            Set-StepperItems $cmbFclk $d.FclkList $fSel
        } else { Set-StepperItems $cmbFclk @("$(if ($d.FclkLive) { $d.FclkLive } else { '?' })") '' }
        $chkFclkAuto.Checked = -not $d.FclkManual
        $script:uclkSel = if ($d.UclkManual) { "$($d.UclkRaw)" } else { 'auto' }
    } finally { $script:filling = $false }
    for ($i = 0; $i -lt $grid.Rows.Count; $i++) { Update-RowStyle $i }
    Update-TopLook; Update-LiveLine; Update-Status; Update-WriteControls
}

# Читает окно. Возвращает @{ want; errors }.
function Get-WantFromForm {
    $want = @{ timings = @{}; speed = 'auto'; fclk = 'auto'; uclk = $(if ($script:uclkSel -eq 'auto') { 'auto' } else { [int]$script:uclkSel }) }; $errors = @()
    for ($i = 0; $i -lt $grid.Rows.Count; $i++) {
        $r = $script:data.Rows[$i]; $row = $grid.Rows[$i]
        if ($null -eq $r.Id) { continue }
        if ([bool]$row.Cells['Auto'].Value) { $want.timings[$r.Key] = 'auto'; continue }
        $txt = "$($row.Cells['New'].Value)".Trim(); $v = 0
        if ($txt -eq '') { $errors += (L 'errEnter' $r.Label); continue }
        if (-not [int]::TryParse($txt, [ref]$v)) { $errors += (L 'errNotNumber' $r.Label $txt); continue }
        $err = Test-Value $r $v
        if ($err) { $errors += "$($r.Label) = ${v}: $err"; continue }
        $want.timings[$r.Key] = $v
    }
    if (-not $chkSpeedAuto.Checked) {
        $sv = Get-StepperValue $cmbSpeed
        if ($null -eq $sv) { $errors += (L 'errPick' (L 'speedName')) } else { $want.speed = [int]$sv }
    }
    if (-not $chkFclkAuto.Checked) {
        $fv = To-IntOrNull (Get-StepperValue $cmbFclk)
        if ($null -eq $fv) { $want.fclk = $script:data.FclkRaw } else { $want.fclk = $fv }
    }
    return @{ want = $want; errors = $errors }
}

function Show-Msg([string]$text, [string]$title, [string]$buttons = 'OK', [string]$icon = 'None', [string]$default = 'Button1') {
    [Windows.Forms.MessageBox]::Show($form, $text, $title, $buttons, $icon, $default)
}

function Reload([string]$message) {
    $form.Cursor = 'WaitCursor'
    try { $script:data = Get-Data; Fill-Form; if ($message) { $status.Text = $message } }
    catch { [void](Show-Msg $_.Exception.Message 'RamPanel' 'OK' 'Error') }
    finally { $form.Cursor = 'Default' }
}

function Do-Apply([bool]$reboot) {
    $grid.EndEdit() | Out-Null
    if (-not (Test-CanWrite)) { [void](Show-Msg $status.Text (L 'roTitle') 'OK' 'Warning'); return }
    $g = Get-WantFromForm
    if ($g.errors.Count) { [void](Show-Msg ($g.errors -join "`r`n") (L 'mbFix') 'OK' 'Warning'); return }
    try { $plan = Get-ApplyPlan $script:data $g.want } catch { [void](Show-Msg $_.Exception.Message 'RamPanel' 'OK' 'Error'); return }
    if (-not $plan.diff.Count) {
        if ($reboot) {
            if ((Show-Msg (L 'mbJustReboot') 'RamPanel' 'YesNo' 'Question') -eq 'Yes') { & shutdown.exe /r /t 15 /c (L 'rebootNote') | Out-Null }
        } else { $status.ForeColor = $P.Muted; $status.Text = L 'stNothing' }
        return
    }
    $msg = ''
    if ($script:sup.Tier -eq 'experimental') { $msg += (L 'mbExperimental') + "`r`n`r`n" }
    $msg += (L 'mbWriteHead') + "`r`n`r`n" + ($plan.diff -join "`r`n") + "`r`n`r`n"
    if ($plan.tighter) { $msg += (L 'mbTighter' $plan.tighter) + "`r`n`r`n" }
    if ($plan.reset) { $msg += $(if ($script:data.Known) { L 'mbReset' } else { L 'mbResetUnknown' }) + "`r`n`r`n" }
    $msg += $(if ($reboot) { L 'mbRebootAfter' } else { L 'mbNextReboot' })
    if ((Show-Msg $msg (L 'mbConfirm') 'YesNo' 'Warning' 'Button2') -ne 'Yes') { return }
    $form.Cursor = 'WaitCursor'
    try {
        $ok = Send-Plan $script:data $g.want $plan
        Reload $(if ($ok) { L 'stWritten' } else { L 'stWrittenUnverified' })
        if ($reboot) { & shutdown.exe /r /t 15 /c (L 'rebootNote') | Out-Null; $status.Text = L 'stRebooting' }
    }
    catch { Log "ERROR: $($_.Exception.Message)"; [void](Show-Msg $_.Exception.Message (L 'mbWriteErr') 'OK' 'Error'); Reload $null }
    finally { $form.Cursor = 'Default' }
}

# ---------------------------------------------------------------- события
$tabMem.Add_Click({ Show-Page 'mem' })
$tabSet.Add_Click({ Show-Page 'set' })
$pillRu.Add_Click({ Set-Language 'ru' })
$pillEn.Add_Click({ Set-Language 'en' })
$chkExp.Add_Click({
    if ($script:filling) { return }
    if ($chkExp.Checked) {
        $txt = L 'expText' $script:dev.Text $(if ($script:sup.Layout) { L 'expLayoutOk' } else { L 'expLayoutUnknown' })
        if ((Show-Msg $txt (L 'expTitle') 'YesNo' 'Warning' 'Button2') -eq 'Yes') { $settings.expDevice = $script:dev.Key; Log "experimental writing enabled for $($script:dev.Text)" }
        else { $settings.expDevice = '' }
    } else { $settings.expDevice = ''; Log "experimental writing disabled for $($script:dev.Text)" }
    Save-Settings
    Fill-Form
})
$grid.Add_CurrentCellDirtyStateChanged({
    if ($grid.IsCurrentCellDirty -and $grid.CurrentCell -and $grid.CurrentCell.OwningColumn.Name -eq 'Auto') { [void]$grid.CommitEdit('CurrentCellChange') }
})
$grid.Add_CellValueChanged({ param($s, $e)
    if ($script:filling -or $e.RowIndex -lt 0) { return }
    $row = $grid.Rows[$e.RowIndex]
    # сняли Auto с пустого поля - подставляем то, что работает сейчас
    if ($grid.Columns[$e.ColumnIndex].Name -eq 'Auto' -and -not [bool]$row.Cells['Auto'].Value -and "$($row.Cells['New'].Value)".Trim() -eq '') {
        $script:filling = $true; try { $row.Cells['New'].Value = "$($script:data.Rows[$e.RowIndex].Live)" } finally { $script:filling = $false }
    }
    Update-RowStyle $e.RowIndex
})
$grid.Add_EditingControlShowing({ param($s, $e) $e.Control.BackColor = $P.Raised; $e.Control.ForeColor = $P.Text })
# галочки Auto в таблице - тем же рисунком, что и сверху
$grid.Add_CellPainting({ param($s, $e)
    if ($e.RowIndex -lt 0 -or $e.ColumnIndex -ne $grid.Columns['Auto'].Index) { return }
    $sel = [bool]($e.State -band [Windows.Forms.DataGridViewElementStates]::Selected)
    $e.PaintBackground($e.CellBounds, $sel)
    $bs = Px 16
    $rc = New-Object Drawing.Rectangle(($e.CellBounds.X + [int](($e.CellBounds.Width - $bs) / 2)), ($e.CellBounds.Y + [int](($e.CellBounds.Height - $bs) / 2)), $bs, $bs)
    Draw-Box $e.Graphics $rc ([bool]$e.Value) $false (Test-RowEditable $script:data.Rows[$e.RowIndex])
    $e.Handled = $true
})
foreach ($c in @($chkSpeedAuto, $chkFclkAuto)) { $c.Add_CheckedChanged({ if (-not $script:filling) { Update-TopLook } }) }
foreach ($b in @($pillU1, $pillU2, $pillUA)) { $b.Add_Click({ param($s, $e) $script:uclkSel = "$($s.Tag)"; Update-TopLook }) }
foreach ($c in @($cmbSpeed, $cmbFclk)) { $c.Tag.onChange = { if (-not $script:filling) { Update-TopLook } } }
$cmbScale.Tag.onChange = { Set-Scale ([double](("$(Get-StepperValue $cmbScale)").TrimEnd('%')) / 100) }
# тёмные полосы прокрутки таблицы (их окна создаются позже самой таблицы)
$form.Add_Shown({ try { [RamPanelNative]::DarkControl($grid.Handle); foreach ($sc in $grid.Controls) { [RamPanelNative]::DarkControl($sc.Handle) }; $grid.Refresh() } catch {} })
$form.Add_KeyDown({ param($s, $e)
    if (-not $e.Control) { return }
    $i = [array]::IndexOf($scaleSteps, $settings.scale)
    if ($e.KeyCode -in 'Oemplus', 'Add') { if ($i -lt $scaleSteps.Count - 1) { Set-Scale $scaleSteps[$i + 1] }; $e.Handled = $true }
    elseif ($e.KeyCode -in 'OemMinus', 'Subtract') { if ($i -gt 0) { Set-Scale $scaleSteps[$i - 1] }; $e.Handled = $true }
    elseif ($e.KeyCode -in 'D0', 'NumPad0') { Set-Scale 1.0; $e.Handled = $true }
})
$form.Add_Resize({ Update-WrapWidths })
$btnRefresh.Add_Click({ Reload $null })
$btnReset.Add_Click({ Fill-Form })
$btnApply.Add_Click({ Do-Apply $false })
$btnApplyRb.Add_Click({ Do-Apply $true })
$btnAllAuto.Add_Click({
    $grid.EndEdit() | Out-Null
    for ($i = 0; $i -lt $grid.Rows.Count; $i++) { if (Test-RowEditable $script:data.Rows[$i]) { $grid.Rows[$i].Cells['Auto'].Value = $true; Update-RowStyle $i } }
    if ($chkSpeedAuto.Enabled) { $chkSpeedAuto.Checked = $true }; if ($chkFclkAuto.Enabled) { $chkFclkAuto.Checked = $true }
    if ($pillUA.Enabled) { $script:uclkSel = 'auto'; Update-TopLook }
    $status.ForeColor = $P.ChangedFg; $status.Text = L 'stAllAuto'
})

$btnSave.Add_Click({
    $grid.EndEdit() | Out-Null
    $g = Get-WantFromForm
    if ($g.errors.Count) { [void](Show-Msg ($g.errors -join "`r`n") (L 'mbFix') 'OK' 'Warning'); return }
    New-Item -ItemType Directory -Force $profDir | Out-Null
    $dlg = New-Object Windows.Forms.SaveFileDialog
    $dlg.InitialDirectory = $profDir; $dlg.Filter = L 'profileFilter'; $dlg.FileName = "profile_{0:yyyyMMdd_HHmm}.json" -f (Get-Date)
    if ($dlg.ShowDialog($form) -ne 'OK') { return }
    $tm = [ordered]@{}; foreach ($k in $T.Keys) { if ($g.want.timings.ContainsKey($k)) { $tm[$k] = $g.want.timings[$k] } }
    [ordered]@{ device = $script:dev.Text; speed = $g.want.speed; fclk = $g.want.fclk; uclk = $g.want.uclk; timings = $tm } | ConvertTo-Json | Set-Content -Path $dlg.FileName -Encoding UTF8
    $status.ForeColor = $P.Muted; $status.Text = L 'stSaved' ([IO.Path]::GetFileName($dlg.FileName))
})

$btnLoad.Add_Click({
    New-Item -ItemType Directory -Force $profDir | Out-Null
    $dlg = New-Object Windows.Forms.OpenFileDialog
    $dlg.InitialDirectory = $profDir; $dlg.Filter = L 'profileFilter'
    if ($dlg.ShowDialog($form) -ne 'OK') { return }
    try {
        $prof = Get-Content $dlg.FileName -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:filling = $true
        try {
            for ($i = 0; $i -lt $grid.Rows.Count; $i++) {
                if (-not (Test-RowEditable $script:data.Rows[$i])) { continue }
                $val = $prof.timings.($script:data.Rows[$i].Key)
                if ($null -eq $val) { continue }
                if ("$val" -eq 'auto') { $grid.Rows[$i].Cells['Auto'].Value = $true }
                else { $grid.Rows[$i].Cells['Auto'].Value = $false; $grid.Rows[$i].Cells['New'].Value = "$([int]$val)" }
            }
            if ("$($prof.speed)" -eq 'auto') { $chkSpeedAuto.Checked = $true } elseif ($prof.speed) { $chkSpeedAuto.Checked = $false; Select-Stepper $cmbSpeed ([int]$prof.speed) }
            if ("$($prof.fclk)" -eq 'auto') { $chkFclkAuto.Checked = $true } elseif ($prof.fclk) { $chkFclkAuto.Checked = $false; Select-Stepper $cmbFclk ([int]$prof.fclk) }
            if ($null -ne $prof.uclk -and $pillUA.Enabled) { $script:uclkSel = $(if ("$($prof.uclk)" -eq 'auto') { 'auto' } else { "$([int]$prof.uclk)" }) }
        } finally { $script:filling = $false }
        for ($i = 0; $i -lt $grid.Rows.Count; $i++) { Update-RowStyle $i }
        Update-TopLook
        $status.ForeColor = $P.ChangedFg; $status.Text = L 'stLoaded' ([IO.Path]::GetFileName($dlg.FileName))
    } catch { [void](Show-Msg (L 'mbProfileErr' $_.Exception.Message) 'RamPanel' 'OK' 'Error') }
})

$chkStart.Add_Click({
    try {
        if ($chkStart.Checked) {
            $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
            $vbs = Join-Path $root 'RamPanel.vbs'
            $action = if (Test-Path $vbs) { New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs`"" -WorkingDirectory $root }
                      else { New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $root 'RamPanel.ps1')`"" -WorkingDirectory $root }
            $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
            $principal = New-ScheduledTaskPrincipal -UserId $user -RunLevel Highest -LogonType Interactive
            $settingsT = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settingsT -Force | Out-Null
            $status.ForeColor = $P.Muted; $status.Text = L 'stStartOn'
        } else {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
            $status.ForeColor = $P.Muted; $status.Text = L 'stStartOff'
        }
    } catch { [void](Show-Msg $_.Exception.Message 'RamPanel' 'OK' 'Error') }
})

# ---------------------------------------------------------------- запуск
Apply-Language
Set-Scale $settings.scale $false
Fill-Form
Show-Page $script:page
if ($script:pending) {
    $status.ForeColor = if ($script:pending.ok) { $P.OkFg } else { $P.BadFg }; $status.Text = $script:pending.text
    if (-not $script:pending.ok) { $form.Add_Shown({ [void](Show-Msg $script:pending.text (L 'pendTitle') 'OK' 'Warning') }) }
}

$form.StartPosition = 'Manual'
$wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Location = New-Object Drawing.Point(($wa.Left + [math]::Max(0, ($wa.Width - $form.Width) / 2)), ($wa.Top + [math]::Max(0, ($wa.Height - $form.Height) / 2)))
[void]$form.ShowDialog()
