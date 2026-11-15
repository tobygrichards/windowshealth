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
- **Sensors use LibreHardwareMonitor**, fetched from nuget.org on first run
  into `lib\`. The exact packages and the SHA-256 of every DLL are pinned in
  `sensor-packages.json`, and every file is re-verified on every run before
  anything is loaded, because the library runs with administrator rights. A
  file that does not match is refused. It loads a kernel driver while the scan
  runs and unloads it afterwards; some anti-cheat systems object to that, so do
  not run the scan with a protected game open.
- **"Partly checked" is not "Healthy".** If something could not be read (no
  voltage rails, a failed event-log query, discarded sensor values) the area
  is shown as "Partly checked" with a "Not checked" entry saying what is
  missing, rather than a green tick.
- **Windows-versus-manufacturer driver conflicts.** For each comparable device
  the dashboard shows the driver in use, who installed it (read from Windows'
  own driver-installation log, `setupapi.dev.log`), and the manufacturer's
  latest. A CONFLICT is raised when Windows (a built-in driver or Windows
  Update) is supplying an older driver than the manufacturer publishes.
  Manufacturer versions are read live from AMD (graphics, chipset), NVIDIA
  (graphics) and ASUS (audio, LAN, Wi-Fi, Bluetooth and BIOS for the exact
  board). Other board makers publish nothing machine-readable, so their
  devices are reported as "not checked", never as "no conflict". Vendors have
  no official API, so a failed lookup is also reported as not verified.
- **Changes since the last run.** Each report saves a compact baseline. The
  next run compares against the most recent report in `reports\` and shows new
  crashes and power losses, drive wear and error counts that moved, drivers
  updated or downgraded, BIOS and Windows build changes, and problems that
  appeared or went away. Keep the `reports` folder for this to work.
- **MSI, Gigabyte and ASRock boards are not compared automatically.** Their
  support sites refuse requests that do not come from a person using a browser,
  and this tool does not try to get round that. For those boards the dashboard
  lists the installed sound, network, Bluetooth and BIOS versions with who
  installed each, and links the board's support page, so you can compare by eye.
- **Naming the driver behind a blue screen needs `cdb.exe`.** Install the
  Windows SDK and tick only "Debugging Tools for Windows".
- **CPU and motherboard sensors need the PawnIO driver.** Without low-level
  access the sensor library returns placeholder values (0 C, 0 W, 1.55 V on
  every core). The tool detects that, discards those readings and says so,
  rather than judging them. Install PawnIO (pawnio.eu) and re-run.
- **Windows Update search** can take a minute. Use `-Offline` to skip it.

## Files

- `Get-PCHealth.ps1` - the collector (pure ASCII, runs on Windows PowerShell 5.1 and PowerShell 7)
- `PCHealth.Rules.ps1` - every limit, threshold and decoding rule, as pure functions with no system access
- `sensor-packages.json` - the pinned sensor library packages and file hashes
- `dashboard.template.html` - the dashboard; the collector embeds the report data into a copy of it
- `Run-PCHealth*.cmd` - launchers that bypass the script execution policy for this one run
- `tests\Run-Tests.ps1` - tests for the rules; `tests\Smoke-Test.ps1` - runs the whole collector against a simulated PC

## Tests

```
powershell -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
pwsh -File tests/Smoke-Test.ps1
```

<img width="1192" height="891" alt="image" src="https://github.com/user-attachments/assets/81c6539a-8f11-4d66-86f5-59531600bd67" />


The rules tests run anywhere. The smoke test needs PowerShell 7 and replaces the
Windows-only queries with a simulated machine, so it proves the collector runs
end to end and judges the simulated data correctly; it does not prove the real
Windows queries return what is expected.
