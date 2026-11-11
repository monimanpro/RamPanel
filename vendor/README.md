# vendor

Two third-party binaries are needed to run RamPanel from the source tree and to build the installer.
They are not stored in this repository.

| File | Project | License | Where to get it |
|---|---|---|---|
| `ZenStates-Core.dll` | [ZenStates-Core](https://github.com/irusanov/ZenStates-Core) by irusanov (tested with 1.79) | GPL-3.0 | build it from the repository, or take it from a [ZenTimings](https://github.com/irusanov/ZenTimings) release |
| `inpoutx64.dll` | [InpOut32 / InpOutx64](https://www.highrez.co.uk/downloads/inpout32/) by Phil Gibbons (Highresolution Enterprises) | MIT — see `InpOut.LICENSE.txt` | the InpOut download page, or a ZenTimings release |

Put both files into this folder, then:

```powershell
powershell -ExecutionPolicy Bypass -File installer\build.ps1
```
