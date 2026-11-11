# Prints the DDR4/DDR5 timings and clocks the memory controller is really running (same source as ZenTimings).
# Uses ZenStates-Core.dll + inpoutx64.dll next to this script (installed copy), else ..\vendor (source tree).
$zt = if (Test-Path (Join-Path $PSScriptRoot 'ZenStates-Core.dll')) { $PSScriptRoot } else { Join-Path (Split-Path $PSScriptRoot) 'vendor' }
[Environment]::CurrentDirectory = $zt
$env:PATH = "$zt;$env:PATH"
[void][Reflection.Assembly]::LoadFrom("$zt\ZenStates-Core.dll")
$names = 'Frequency','GDM','Cmd2T','CL','RCDWR','RCDRD','RP','RAS','RC','RRDS','RRDL','FAW','WTRS','WTRL','WR',
         'RFC','RFC2','RFCsb','RTP','RDRDSCL','WRWRSCL','CWL','RDWR','WRRD','RDRDSC','RDRDSD','RDRDDD','WRWRSC','WRWRSD','WRWRDD','REFI'
$cpu = New-Object ZenStates.Core.Cpu((New-Object ZenStates.Core.CpuInitSettings))
try {
    $mc = $cpu.GetMemoryConfig()
    $t = $mc.Timings[0]
    if ($t.Value) { $t = $t.Value }
    $have = @($t.PSObject.Properties | ForEach-Object Name)
    $out = [ordered]@{}
    foreach ($n in $names) { $out[$n] = $(if ($have -contains $n) { "$($t.$n)" } else { '' }) }
    $out['Type'] = "$($mc.Type)"
    # clocks from the SMU power table (MHz); empty when the table cannot be read
    $out['FCLK'] = ''; $out['UCLK'] = ''; $out['MCLK'] = ''
    try {
        [void]$cpu.RefreshPowerTable()
        $pt = $cpu.powerTable
        if ($pt) { $out['FCLK'] = "$([math]::Round($pt.FCLK))"; $out['UCLK'] = "$([math]::Round($pt.UCLK))"; $out['MCLK'] = "$([math]::Round($pt.MCLK))" }
    } catch {}
    $out | ConvertTo-Json -Compress
} finally { $cpu.Dispose() }
