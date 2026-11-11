# How RamPanel works

Notes from building and testing RamPanel on a Lenovo Legion R7000P 16ADR10 (BIOS RLCN31WW, Insyde, AMD Ryzen 9 8945HX,
Dragon Range / Raphael platform, 2 × DDR5 SO-DIMM). Other machines may differ; everything below that is not marked as
generic was observed on that laptop only.

## 1. Reading what runs

`src/Get-LiveTimings.ps1` loads ZenStates-Core and prints the active DDR timings (`GetMemoryConfig().Timings`) plus
FCLK / UCLK / MCLK from the SMU power table (`RefreshPowerTable()`), as JSON. It runs in a separate PowerShell process so
that the panel never holds the hardware-access driver open.

## 2. Writing: AMD overclocking WMI interface

Many AMD BIOSes expose an ACPI WMI device `ACPI\PNP0C14\AOD_0`, visible as WMI class `AMD_ACPI` in `root\wmi`
(interface version 6 on this laptop). Methods:

| Method | Use |
|---|---|
| `GetObjectID`, `GetObjectID2` | list of supported commands: ID + human-readable name (`Set Tcl`, `Set Mem Clock`, …) |
| `GetMinMaxSteppingValues(ID)` | `Current` (the running value), `Min`, `Max`, `Stepping` |
| `Getdvalues(ID)` | list of allowed discrete values (memory clock, FCLK, UCLK mode) |
| `RunCommand(Inbuf)` | executes one command; `Inbuf` = 8 bytes: command ID (u32 LE) + argument (u32 LE) |

A write is a "command buffer": `Command Buffer Start` (0x40001), the `Set …` commands, `Command Buffer End` (0x40002).
The BIOS stores the values and applies them on the next boot.

RamPanel looks commands up **by name**, so it does not depend on the IDs below; they are listed for reference
(as reported by RLCN31WW):

| Name | ID | Argument |
|---|---|---|
| Set Tcl / Trcd / Trp / Tras / Trc / Twr | 0x20002 / 0x2003B / 0x20006 / 0x20005 / 0x20009 / 0x20010 | clocks |
| Set Trfc1 / Trfc2 / TrfcSb | 0x2003C / 0x2000B / 0x2003D | clocks |
| Set Trtp / TrrdL / TrrdS / Tfaw / TwtrL / TwtrS | 0x20015 / 0x2000F / 0x2000E / 0x2000D / 0x20012 / 0x20011 | clocks |
| Set TrdrdScL / TrdrdSc / TrdrdSd / TrdrdDd | 0x20017 / 0x20016 / 0x20018 / 0x20019 | clocks |
| Set TwrwrScL / TwrwrSc / TwrwrSd / TwrwrDd | 0x2001B / 0x2001A / 0x2001C / 0x2001D | clocks |
| Set Twrrd / Trdwr | 0x2001F / 0x2001E | clocks |
| Set Mem Clock | 0x20001 | MCLK in MHz (= MT/s ÷ 2) |
| Set FCLK Frequency | 0x20035 | MHz |
| Set UCLK DIV1 | 0x20044 | 1 = UCLK:MCLK 1:1, 0 = 1:2 |
| Reset Mem Para | 0x20048 | — |

Observed behaviour worth knowing:

- **No range check.** `Set T…` stores whatever number it receives (0 and 65535 were accepted). Only RamPanel validates
  against `GetMinMaxSteppingValues`.
- **No per-field Auto.** The only way back to Auto is `Reset Mem Para`, which sets *all* timings, the memory clock, FCLK
  and the UCLK mode to Auto and nothing else. RamPanel therefore does "Auto for some fields" as: reset, then write every
  field that should stay manual again.
- `GetMinMaxSteppingValues(...).Current` shows the running value, not the stored one.

## 3. Verifying a write

The AOD settings are mirrored in a UEFI variable named `AodSetup*` with vendor GUID
`5ed15dc0-edef-4161-9151-6014c4cc630c` (`AodSetupRpl`, 428 bytes, on this laptop). It can be read from Windows
(`GetFirmwareEnvironmentVariableExW`) but not written — writes fail with ERROR_WRITE_PROTECT, which is why RamPanel uses
the WMI interface.

Layout of `AodSetupRpl` (RLCN31WW):

| Offset | Content |
|---|---|
| 0x3C | memory speed flag: 1 = manual, 0xFF = Auto |
| 0x3D | memory speed, MT/s (u16) |
| 0x3F … 0x89 | 25 timings, 3 bytes each: flag (1 = manual, 0 = Auto) + value (u16), in the order of the table above (tCL first) |
| 0x94 | FCLK, MHz (u16), 0xFFFF = Auto |
| 0x96 | UCLK mode: 1 = 1:1, 0 = 1:2, 0xFF = Auto |

On a verified device RamPanel reads the variable before and after a write and checks that exactly the requested fields
changed. On other devices the layout is trusted only if the variable name/size is known and passes a sanity check;
otherwise the write is checked after the next reboot (step 5).

## 4. What the BIOS does after a failed boot (APCB recovery)

Memory settings end up in the APCB (AMD's configuration block in the SPI flash) that the PSP's ABL firmware uses for
memory training. The DXE driver `AmdPspDxeV2Rpl` implements AMD's **APCB recovery**: when ABL reports a recovery flag,
the driver copies the backup (default) APCB over the active one, writes `0x5A, 0xA5` to extended CMOS
(ports 0x72/0x73, indexes 6–7) and reboots. If recovery is disabled by PCD, it writes `0x55, 0x55` instead. On this
laptop indexes 6–7 read `5A A5`, so recovery is enabled.

Practical consequence: the BIOS falls back to defaults on its own **only when ABL sees the failure** (for example memory
training fails — typical for too-tight primary timings). If training passes and the system hangs later (seen with a too
short tRFC), nothing triggers recovery and a manual CMOS reset is needed.

## 5. Checking after a reboot

Every write saves the requested values to `rampanel.pending.json`. On the first start after a reboot RamPanel compares
them with the running timings and clocks and reports anything that did not apply. Until that reboot, on devices with an
unknown BIOS layout, the same file is used as "what is stored in the BIOS", so a fresh write can still be undone.
