# PC Health Check

A passive health check for a Windows 10/11 PC. It reads evidence that already
exists on the machine and writes an HTML dashboard. It never runs a stress
test, benchmark or surface scan, so it adds no wear to any component.

## Run it

1. Copy this folder to the Windows PC.
2. Double-click `Run-PCHealth.cmd` and accept the administrator prompt.
3. The dashboard opens in your browser. Reports are kept in `reports\`
   (HTML plus the raw JSON), so you can compare runs over time.

`Run-PCHealth-DeepScan.cmd` additionally runs the read-only
`DISM /ScanHealth` and `sfc /verifyonly` (10-20 minutes).

`Run-PCHealth-Watch.cmd` keeps reading the sensors for 20 minutes while you
use the PC (play a demanding game), then reports the lowest and highest value
of every sensor: 12 V rail sag, peak temperatures, peak CPU and GPU power. The
tool generates no load itself, so this adds no wear beyond your normal use.

Options for `Get-PCHealth.ps1`:

| Switch | Effect |
|---|---|
| `-DeepScan` | Add the DISM and SFC verification |
| `-NoSensors` | Do not load LibreHardwareMonitor (no kernel driver, no temperatures or voltages) |
| `-WatchMinutes 20` | Record sensor minimum and maximum over that many minutes of your own use |
| `-Offline` | No network calls at all |
| `-Days 90` | Event-log look-back window (default 30) |
| `-OutDir`, `-NoOpen` | Report location; do not open the browser |

## What it checks

| Area | Evidence |
|---|---|
| Crashes | A timeline of every blue screen and unexpected shutdown: bugcheck code decoded to a prime suspect, the hardware, GPU and disk errors logged around it, the pattern across crashes, plus application crashes by faulting module. If Microsoft's `cdb.exe` debugger is installed, the three newest minidumps are analysed to name the faulting driver |
| CPU | Machine-check (WHEA) errors, firmware throttling events, temperature, microcode revision |
| GPU | Driver crash/recovery (TDR) events, GPU watchdog dumps, device error codes, temperature |
| Memory | WHEA memory errors, last Windows Memory Diagnostic result, rated versus running speed |
| Drives | SMART / NVMe health log (life used, temperature, uncorrected errors), failure prediction, disk error events, free space |
| Power supply | Voltage rails from the motherboard sensor chip against ATX tolerance, unexpected power-loss events, laptop battery wear |
| Motherboard | PCIe/bus errors, BIOS age, CMOS battery voltage, Secure Boot, TPM |
| Windows | Component store state, blue-screen history, pending and failed updates, pending restart, Defender, failed services |
| Drivers | Inventory with age and signing, failed devices, live GPU driver version check, Windows Update downgrade offers, staged-versus-active driver mismatch, where to download each driver |

## Things to know

- **PSU and motherboard verdicts are inferred.** Most PSUs have no data link to
  the PC, and a passive check cannot prove stability under load. A clean report
  means "no evidence of a fault", not "proven good".
- **Sensors use LibreHardwareMonitor**, downloaded from its GitHub releases on
  first run into `lib\`. It loads a kernel driver while the scan runs and
  unloads it afterwards. Some anti-cheat systems object to that driver, so do
  not run the scan with a protected game open. Recent releases may also need
  the separate PawnIO driver for CPU and motherboard sensors; the dashboard
  says so if those readings are missing.
- **Installed-versus-latest is checked live for AMD graphics, AMD chipset and
  NVIDIA graphics**, by reading the vendor's own download page for the exact
  product. Vendors publish no official API, so if a site changes the lookup is
  reported as "Not verified", never as "up to date". Intel graphics is
  best-effort. Motherboard-maker items (BIOS, audio, LAN) are not version
  checked; the dashboard links to the support page instead.
- **Naming the driver behind a blue screen needs `cdb.exe`.** Install the
  Windows SDK and tick only "Debugging Tools for Windows".
- **CPU and motherboard sensors need the PawnIO driver.** Without low-level
  access the sensor library returns placeholder values (0 C, 0 W, 1.55 V on
  every core). The tool detects that, discards those readings and says so,
  rather than judging them. Install PawnIO (pawnio.eu) and re-run.
- **Windows Update search** can take a minute. Use `-Offline` to skip it.

## Files

- `Get-PCHealth.ps1` - the collector (pure ASCII, runs on Windows PowerShell 5.1 and PowerShell 7)
- `dashboard.template.html` - the dashboard; the collector embeds the report data into a copy of it
- `Run-PCHealth.cmd`, `Run-PCHealth-DeepScan.cmd` - launchers that bypass the script execution policy for this one run
