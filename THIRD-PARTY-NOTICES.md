# Third-party components

RamPanel's own code is in `src/` and `installer/` (GPL-3.0, see `LICENSE`). The installer built by `installer/build.ps1`
also carries these binaries unchanged:

## ZenStates-Core

- Project: https://github.com/irusanov/ZenStates-Core (author: irusanov)
- Version used and tested: 1.79 (`ZenStates-Core.dll`, the copy shipped with ZenTimings 1.36)
- License: GNU General Public License v3.0 — the full text is in `LICENSE` of this repository.
- Used for: reading the running memory timings and clocks (the same data ZenTimings shows).
- The source for this exact component is available from the project repository above.
- ZenStates-Core itself credits ryzen_smu, ryzen_nb_smu, zenpower, the Linux kernel, AMD public documentation and
  Open Hardware Monitor; see its repository for their terms.

## InpOut32 / InpOutx64

- Project: https://www.highrez.co.uk/downloads/inpout32/ (Phil Gibbons, Highresolution Enterprises; portions logix4u.net)
- File: `inpoutx64.dll` (the kernel driver is embedded in the DLL and installed on first use)
- License: MIT — the full text is in `vendor/InpOut.LICENSE.txt`.
- Used by ZenStates-Core for hardware access.

## Tools used while building RamPanel (not shipped)

- ZenTimings by irusanov — reference for the live timing values and source of the two DLLs above.
- Ghidra (NSA) through the REA MCP server — used to study the laptop BIOS; no BIOS code is included in this repository.
- 7-Zip — unpacking the Lenovo BIOS update package for that study.
- .NET Framework C# compiler (`csc.exe`, part of Windows) — builds the setup executable.
