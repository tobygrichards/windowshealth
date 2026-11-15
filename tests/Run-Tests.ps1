# Tests for PCHealth.Rules.ps1. No dependencies: run with
#   powershell -ExecutionPolicy Bypass -File tests\Run-Tests.ps1      (Windows PowerShell 5.1)
#   pwsh -File tests/Run-Tests.ps1                                    (PowerShell 7, any OS)
# Exit code is the number of failed tests.

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'PCHealth.Rules.ps1')

$script:Pass = 0; $script:Fail = 0
function Check([string]$name, $actual, $expected) {
    if ("$actual" -eq "$expected") { $script:Pass++ }
    else { $script:Fail++; Write-Host ('FAIL  {0}: expected [{1}] got [{2}]' -f $name, $expected, $actual) -ForegroundColor Red }
}
function Sensor([string]$hwType, [string]$type, [string]$name, [double]$value, [hashtable]$extra) {
    $o = [pscustomobject]@{ Hw = 'dev'; HwType = $hwType; Id = '/x/0'; Name = $name; Type = $type; Value = $value; Min = $value; Max = $value; Valid = $true; Note = ''; Step = 0.0 }
    if ($extra) { foreach ($k in $extra.Keys) { $o.$k = $extra[$k] } }
    return $o
}

# ---- versions
Check 'version compare' ((ConvertTo-Ver '26.11.1') -gt (ConvertTo-Ver '26.10.1')) $true
Check 'bad version is null' ($null -eq (ConvertTo-Ver 'abc')) $true
Check 'max version keeps vendor text' (Get-MaxVer 'amd_chipset_software_8.09.28.1124.exe amd_chipset_software_7.01.1.5.exe' 'amd_chipset_software_(\d+\.\d+\.\d+(?:\.\d+)?)') '8.09.28.1124'
Check 'max version none' (Get-MaxVer 'nothing here' 'v(\d+\.\d+)') ''
Check 'whql only' (Get-MaxVer 'whql-amd-software-adrenalin-edition-26.10.1-win11 amd-software-adrenalin-edition-26.11.1-win11' 'whql-amd-software-adrenalin-edition-(\d{2}\.\d{1,2}\.\d{1,2})') '26.10.1'
Check 'optional excludes whql' (Get-MaxVer 'whql-amd-software-adrenalin-edition-26.12.1-win11 amd-software-adrenalin-edition-26.11.1-win11' '(?<!whql-)amd-software-adrenalin-edition-(\d{2}\.\d{1,2}\.\d{1,2})-win') '26.11.1'

# ---- AMD naming
Check 'slug gpu' (Get-AmdSlug 'AMD Radeon RX 9070 XT') 'amd-radeon-rx-9070-xt'
Check 'slug gpu tm' (Get-AmdSlug 'AMD Radeon(TM) RX 6800 XT') 'amd-radeon-rx-6800-xt'
Check 'slug cpu' (Get-AmdSlug 'AMD Ryzen 9 5950X 16-Core Processor') 'amd-ryzen-9-5950x'
Check 'slug igpu cpu' (Get-AmdSlug 'AMD Ryzen 5 5600G with Radeon Graphics') 'amd-ryzen-5-5600g'
Check 'chipset x570-e' (Get-AmdChipsetToken 'ROG STRIX X570-E GAMING WIFI II') 'x570'
Check 'chipset x670e-e' (Get-AmdChipsetToken 'ROG STRIX X670E-E GAMING WIFI') 'x670e'
Check 'chipset b650m' (Get-AmdChipsetToken 'B650M-A') 'b650'
Check 'chipset none' (Get-AmdChipsetToken 'System Product Name') ''
Check 'tjmax 5950X' (Get-CpuTjMax 'AMD Ryzen 9 5950X 16-Core Processor') 90
Check 'tjmax x3d' (Get-CpuTjMax 'AMD Ryzen 7 7800X3D 8-Core Processor') 89
Check 'tjmax intel' (Get-CpuTjMax 'Intel(R) Core(TM) i7-13700K') 100

# ---- rails
Check 'rail +12V' (Get-RailNominal '+12V') 12
Check 'rail 5VSB' (Get-RailNominal '5VSB') 5
Check 'rail 3VCC' (Get-RailNominal '3VCC') 3.3
Check 'rail not 1.05V' (Get-RailNominal '+1.05V') 0
Check 'rail not vcore' (Get-RailNominal 'Vcore') 0
Check 'rail not voltage #5' (Get-RailNominal 'Voltage #5') 0

# ---- sensor verdicts
$script:CpuTjMax = 90
Check 'cpu temp ok' (Get-SensorVerdict (Sensor 'Cpu' 'Temperature' 'Core (Tctl/Tdie)' 60) @())[0] 'ok'
Check 'cpu temp warn near limit' (Get-SensorVerdict (Sensor 'Cpu' 'Temperature' 'Core (Tctl/Tdie)' 88) @())[0] 'warn'
Check 'cpu temp crit' (Get-SensorVerdict (Sensor 'Cpu' 'Temperature' 'Core (Tctl/Tdie)' 94) @())[0] 'crit'
Check 'cpu range text' (Get-SensorVerdict (Sensor 'Cpu' 'Temperature' 'Core (Tctl/Tdie)' 60) @())[3] '10 to 85 C'
Check 'distance to tjmax is reference' (Get-SensorVerdict (Sensor 'Cpu' 'Temperature' 'Core #1 Distance to TjMax' 20) @())[0] ''
Check 'unlabelled chip input not judged' (Get-SensorVerdict (Sensor 'SuperIO' 'Temperature' 'Temperature #6' 92) @())[0] ''
Check 'unlabelled reason' (Get-SensorVerdict (Sensor 'SuperIO' 'Temperature' 'Temperature #6' 92) @())[1] 'Not judged: unlabelled input on the sensor chip'
Check 'invalid sensor' (Get-SensorVerdict (Sensor 'Cpu' 'Temperature' 'Core' 0 @{ Valid = $false }) @())[0] 'info'
Check 'invalid shows note' (Get-SensorVerdict (Sensor 'Cpu' 'Temperature' 'Core' 0 @{ Valid = $false; Note = 'Erratic: x' }) @())[1] 'Erratic: x'
Check 'clock has no range' (Get-SensorVerdict (Sensor 'Cpu' 'Clock' 'Core #1' 5050) @())[3] ''
Check 'gpu hot spot ok at 95' (Get-SensorVerdict (Sensor 'GpuAmd' 'Temperature' 'GPU Hot Spot' 95) @())[0] 'ok'
Check 'gpu core warn at 95' (Get-SensorVerdict (Sensor 'GpuAmd' 'Temperature' 'GPU Core' 95) @())[0] 'warn'
Check 'vrm crit not capped on EC' (Get-SensorVerdict (Sensor 'EmbeddedController' 'Temperature' 'VRM' 120) @())[0] 'crit'
Check 'chipset ok' (Get-SensorVerdict (Sensor 'EmbeddedController' 'Temperature' 'Chipset' 49) @())[0] 'ok'

# rails: in tolerance, out of tolerance, collapsed, and unscaled
Check '12V ok' (Get-SensorVerdict (Sensor 'EmbeddedController' 'Voltage' '+12V' 12.1) @())[0] 'ok'
Check '12V warn at -6%' (Get-SensorVerdict (Sensor 'EmbeddedController' 'Voltage' '+12V' 11.28) @())[0] 'warn'
Check '12V crit at -10%' (Get-SensorVerdict (Sensor 'EmbeddedController' 'Voltage' '+12V' 10.8) @())[0] 'crit'
Check '12V collapsed to 10.0 is still judged' (Get-SensorVerdict (Sensor 'EmbeddedController' 'Voltage' '+12V' 10.0) @())[0] 'crit'
Check '12V reading 1.0 is unscaled' (Get-SensorVerdict (Sensor 'SuperIO' 'Voltage' '+12V' 1.0) @())[0] ''
Check 'chip never raises critical' (Get-SensorVerdict (Sensor 'SuperIO' 'Voltage' '+12V' 10.0) @())[0] 'warn'
Check 'chip warning says low confidence' ((Get-SensorVerdict (Sensor 'SuperIO' 'Voltage' '+12V' 10.0) @())[1] -match 'Low-confidence') $true
Check '12V judged on watched minimum' (Get-SensorVerdict (Sensor 'EmbeddedController' 'Voltage' '+12V' 12.0 @{ Min = 11.2; Max = 12.1 }) @())[0] 'warn'
Check 'vbat low' (Get-SensorVerdict (Sensor 'SuperIO' 'Voltage' 'VBAT' 2.5) @())[0] 'warn'
Check 'vbat ok' (Get-SensorVerdict (Sensor 'SuperIO' 'Voltage' 'VBAT' 3.1) @())[0] 'ok'
Check 'vcore 1.45 ok' (Get-SensorVerdict (Sensor 'Cpu' 'Voltage' 'Core (SVI2 TFN)' 1.45) @())[0] 'ok'
Check 'vcore 1.56 crit' (Get-SensorVerdict (Sensor 'Cpu' 'Voltage' 'Core (SVI2 TFN)' 1.56) @())[0] 'crit'
Check 'cpu VID named with 5V-like text not a rail' (Get-SensorVerdict (Sensor 'Cpu' 'Voltage' 'Core #5 VID' 1.2) @())[0] ''
Check 'cpu fan stopped' (Get-SensorVerdict (Sensor 'SuperIO' 'Fan' 'CPU Fan' 0) @())[0] 'warn'
Check 'cpu fan spinning' (Get-SensorVerdict (Sensor 'SuperIO' 'Fan' 'CPU Fan' 900) @())[0] 'ok'
Check 'pump header ignored' (Get-SensorVerdict (Sensor 'SuperIO' 'Fan' 'CPU Pump' 0) @())[0] ''

# ---- drive limits come from the drive itself, matched by identifier
$pny = @(
    (Sensor 'Storage' 'Temperature' 'Composite Temperature' 40 @{ Hw = 'PNY CS3140 2TB SSD'; Id = '/nvme/1' }),
    (Sensor 'Storage' 'Temperature' 'Warning Temperature' 81 @{ Hw = 'PNY CS3140 2TB SSD'; Id = '/nvme/1' }),
    (Sensor 'Storage' 'Temperature' 'Critical Temperature' 83 @{ Hw = 'PNY CS3140 2TB SSD'; Id = '/nvme/1' }))
Check 'drive own warning limit' (Get-DriveTempLimits $pny '/nvme/1')[0] 81
Check 'drive own critical limit' (Get-DriveTempLimits $pny '/nvme/1')[1] 83
Check 'drive default limits' (Get-DriveTempLimits $pny '/nvme/9')[0] 70
Check 'hdd default limits' (Get-DriveTempLimits @() '/hdd/2')[0] 55
Check 'drive reading ok against own limit' (Get-SensorVerdict $pny[0] $pny)[0] 'ok'
Check 'drive limit row is reference' (Get-SensorVerdict $pny[1] $pny)[1] 'Reference value, not a reading'
Check 'drive limit row not flagged' (Get-SensorVerdict $pny[2] $pny)[0] ''
$hot = Sensor 'Storage' 'Temperature' 'Composite Temperature' 78 @{ Hw = 'PNY CS3140 2TB SSD'; Id = '/nvme/1' }
Check 'drive warn within 5 C of own limit' (Get-SensorVerdict $hot $pny)[0] 'warn'

# ---- erratic readings
Check 'temp jump is erratic' ((Test-SensorErratic (Sensor 'SuperIO' 'Temperature' 'CPU' 50 @{ Step = 30 })) -ne '') $true
Check 'temp steady is fine' (Test-SensorErratic (Sensor 'SuperIO' 'Temperature' 'CPU' 50 @{ Step = 3 })) ''
Check 'rail jump is erratic' ((Test-SensorErratic (Sensor 'SuperIO' 'Voltage' '+12V' 12 @{ Step = 2 })) -ne '') $true
Check 'vcore swing is NOT erratic' (Test-SensorErratic (Sensor 'SuperIO' 'Voltage' 'Vcore' 1.4 @{ Step = 0.5 })) ''
Check 'cpu vid swing is NOT erratic' (Test-SensorErratic (Sensor 'Cpu' 'Voltage' 'Core #1 VID' 1.4 @{ Step = 0.5 })) ''

# ---- two identical drives must not share readings
$twins = @(
    (Sensor 'Storage' 'Data' 'Data Written' 100 @{ Hw = 'Samsung SSD 990 PRO 1TB'; Id = '/nvme/0' }),
    (Sensor 'Storage' 'Data' 'Data Written' 9000 @{ Hw = 'Samsung SSD 990 PRO 1TB'; Id = '/nvme/2' }),
    (Sensor 'Storage' 'Data' 'Data Written' 5 @{ Hw = 'PNY CS3140 2TB SSD'; Id = '/nvme/1' }))
Check 'twin drive 0' (Select-DriveSensors $twins 'Samsung SSD 990 PRO 1TB' 0)[0].Value 100
Check 'twin drive 2' (Select-DriveSensors $twins 'Samsung SSD 990 PRO 1TB' 2)[0].Value 9000
Check 'twin undecidable gives nothing' @(Select-DriveSensors $twins 'Samsung SSD 990 PRO 1TB' 7).Count 0
Check 'single drive ignores disk number' (Select-DriveSensors $twins 'PNY CS3140 2TB SSD' 5)[0].Value 5
Check 'unknown drive gives nothing' @(Select-DriveSensors $twins 'ST2000DM008-2FR102' 3).Count 0

# ---- crash to blue-screen pairing
$t0 = [datetime]'2026-11-10 20:00:00'
$recs = @(
    [pscustomobject]@{ RecordId = 2; TimeCreated = $t0.AddMinutes(12) },   # belongs to the second crash
    [pscustomobject]@{ RecordId = 1; TimeCreated = $t0.AddMinutes(1) })    # belongs to the first crash
$used = @{}
$first = Select-NearestRecord $recs $t0 $used 2 30
Check 'nearest record for first crash' $first.RecordId 1
$used[$first.RecordId] = 1
Check 'second crash gets the other record' (Select-NearestRecord $recs $t0.AddMinutes(10) $used 2 30).RecordId 2
Check 'claimed record is not reused' ($null -eq (Select-NearestRecord $recs $t0 @{ 1 = 1; 2 = 1 } 2 30)) $true
Check 'outside window' ($null -eq (Select-NearestRecord $recs $t0.AddHours(5) @{} 2 30)) $true

# ---- bugcheck decoding
Check 'bugcheck 0x124' (Resolve-Bugcheck 0x124)[0] 'WHEA_UNCORRECTABLE_ERROR'
Check 'bugcheck 0x124 suspect' (Resolve-Bugcheck 0x124)[1] 'Hardware'
Check 'bugcheck 0x1000007E strips flag' (Resolve-Bugcheck 0x1000007E)[0] 'SYSTEM_THREAD_EXCEPTION_NOT_HANDLED'
Check 'bugcheck unknown' (Resolve-Bugcheck 0xDEAD)[1] 'Unknown'
Check 'bugcheck huge code does not throw' (Resolve-Bugcheck 0xC000021A)[1] 'Unknown'

# ---- area status
function F([string]$sev) { return @{ sev = $sev } }
Check 'status empty' (Get-AreaStatus @())[0] 'unknown'
Check 'status ok' (Get-AreaStatus @((F 'ok'), (F 'info')))[0] 'ok'
Check 'status gap is limited, not ok' (Get-AreaStatus @((F 'ok'), (F 'gap')))[0] 'limited'
Check 'status only gap is limited' (Get-AreaStatus @((F 'gap')))[0] 'limited'
Check 'status warn beats gap' (Get-AreaStatus @((F 'gap'), (F 'warn')))[0] 'warn'
Check 'status crit beats warn' (Get-AreaStatus @((F 'warn'), (F 'crit')))[0] 'crit'
Check 'overall ignores limited' (Get-OverallStatus @('ok', 'limited', 'unknown')) 'ok'
Check 'overall warn' (Get-OverallStatus @('ok', 'warn', 'limited')) 'warn'
Check 'overall crit' (Get-OverallStatus @('warn', 'crit')) 'crit'

# ---- who installed a driver (setupapi.dev.log)
$log = @(
    '>>>  [Device Install (Windows Update) - PCI\VEN_1002&DEV_7550]',
    '>>>  Section start 2026/11/15 10:07:12.123',
    '      cmd: C:\WINDOWS\system32\svchost.exe -k netsvcs -p -s wuauserv',
    '     dvi: Created Driver Node: InfName - c:\windows\inf\oem3.inf',
    '     sto: {Setup Import Driver Package: c:\windows\softwaredistribution\download\install\u0412345.inf} 10:07:13.000',
    "     cpy:           Published 'u0412345.inf_amd64_abc\u0412345.inf' to 'C:\WINDOWS\INF\oem42.inf'.",
    '<<<  Section end 2026/11/15 10:07:30.000',
    '>>>  [Setup Import Driver Package - C:\AMD\Chipset\amdgpio2.inf]',
    '>>>  Section start 2026/10/18 14:00:00.000',
    '      cmd: "C:\AMD\Chipset_Software\Setup.exe" -install',
    "     cpy:           Published 'amdgpio2.inf_amd64_def\amdgpio2.inf' to 'C:\WINDOWS\INF\oem7.inf'.",
    '<<<  Section end 2026/10/18 14:00:05.000',
    '>>>  [Device Install (Hardware initiated) - USB\VID_046D]',
    '>>>  Section start 2026/10/19 09:00:00.000',
    '     dvi: Selected driver installs from section in c:\windows\inf\oem9.inf',
    '<<<  Section end 2026/10/19 09:00:01.000')
$o = Get-DriverOriginsFromSetupLog $log
Check 'log: WU-published package' $o['oem42.inf'].Origin 'Windows Update'
Check 'log: WU date' $o['oem42.inf'].When '2026/11/15'
Check 'log: vendor-published package' $o['oem7.inf'].Origin 'Manufacturer installer'
Check 'log: vendor installer name' $o['oem7.inf'].By 'setup.exe'
Check 'log: package only considered by WU is not tagged' $o.ContainsKey('oem3.inf') $false
Check 'log: plain device binding is not tagged' $o.ContainsKey('oem9.inf') $false
Check 'origin inbox' (Get-DriverOrigin 'netrtwlane.inf' '1.0' $o @())[1] 'windows-inbox'
Check 'origin WU from log' (Get-DriverOrigin 'OEM42.INF' '32.0.31044.16' $o @())[1] 'windows-update'
Check 'origin WU text' (Get-DriverOrigin 'oem42.inf' '32.0.31044.16' $o @())[0] 'Windows Update on 2026-11-15'
Check 'origin manufacturer' (Get-DriverOrigin 'oem7.inf' '2.2.0.130' $o @())[1] 'manufacturer'
Check 'origin WU from history when log silent' (Get-DriverOrigin 'oem99.inf' '6.0.9700.1' $o @('Realtek - MEDIA - 6.0.9700.1'))[1] 'windows-update'
Check 'origin unknown' (Get-DriverOrigin 'oem99.inf' '6.0.9700.1' $o @('Something else'))[1] 'unknown'
Check 'log beats history' (Get-DriverOrigin 'oem7.inf' '2.2.0.130' $o @('AMD - System - 2.2.0.130'))[1] 'manufacturer'

# ---- conflict verdicts
Check 'conflict: WU older than manufacturer' (Get-ConflictVerdict 'windows-update' '6.0.9411.1' '6.0.9700.1' $true)[2] $true
Check 'conflict severity' (Get-ConflictVerdict 'windows-update' '6.0.9411.1' '6.0.9700.1' $true)[0] 'warn'
Check 'conflict: inbox older than manufacturer' (Get-ConflictVerdict 'windows-inbox' '1.0.0.1' '1.2.0.0' $true)[2] $true
Check 'no conflict: WU same as manufacturer' (Get-ConflictVerdict 'windows-update' '6.0.9700.1' '6.0.9700.1' $true)[0] 'ok'
Check 'no conflict: WU newer than manufacturer' (Get-ConflictVerdict 'windows-update' '6.0.9800.1' '6.0.9700.1' $true)[2] $false
Check 'manufacturer-installed but old is not a conflict' (Get-ConflictVerdict 'manufacturer' '6.0.9411.1' '6.0.9700.1' $true)[2] $false
Check 'manufacturer-installed but old still warns' (Get-ConflictVerdict 'manufacturer' '6.0.9411.1' '6.0.9700.1' $true)[0] 'warn'
Check 'different series not compared' (Get-ConflictVerdict 'windows-update' '10.72.524.2024' '1125.27.50.919' $true)[0] 'gap'
Check 'series check off for package versions' (Get-ConflictVerdict 'windows-update' '25.9.1' '26.10.1' $false)[2] $true
Check 'no vendor version' (Get-ConflictVerdict 'windows-update' '1.0' '' $true)[0] ''
Check 'unparsable version' (Get-ConflictVerdict 'windows-update' 'abc' '1.0' $true)[0] 'gap'

# ---- board maker listing
Check 'asus slug' (Get-AsusModelSlug 'ROG STRIX X570-E GAMING WIFI II') 'ROG-STRIX-X570-E-GAMING-WIFI-II'
Check 'asus slug brackets' (Get-AsusModelSlug 'TUF GAMING X570-PLUS (WI-FI)') 'TUF-GAMING-X570-PLUS-WI-FI'
$listing = @(
    [pscustomobject]@{ Category = 'LAN'; Version = '1125.21.903.2024'; Title = 'Realtek LAN Driver V1125.21.903.2024 for Windows 11 64-bit.'; Date = '2024/09/18' },
    [pscustomobject]@{ Category = 'LAN'; Version = '1125.27.50.919'; Title = 'Realtek RTL8125 LAN driver v1125.27.50.919 for Windows 11 64-bit.'; Date = '2025/12/31' },
    [pscustomobject]@{ Category = 'LAN'; Version = '14.1.3.0'; Title = 'Intel I211 Gigabit Ethernet Driver V14.1.3.0'; Date = '2025/01/01' },
    [pscustomobject]@{ Category = 'Audio'; Version = '6.0.9700.1'; Title = 'Realtek Audio Driver v6.0.9700.1 for windows 11 64-bit.'; Date = '2024/09/24' },
    [pscustomobject]@{ Category = 'Audio'; Version = '6.0.9411.1'; Title = 'Realtek Audio Driver V6.0.9411.1 For Windows 10/11 64-bit.'; Date = '2022/10/21' },
    [pscustomobject]@{ Category = 'Wireless'; Version = '3.5.0.1349'; Title = 'MediaTek WiFi Driver V3.5.0.1349 For Windows 10/11 64-bit.'; Date = '2026/03/06' },
    [pscustomobject]@{ Category = 'Bluetooth'; Version = '1.1044.0.556'; Title = 'MediaTek Bluetooth Driver V1.1044.0.556'; Date = '2026/03/06' },
    [pscustomobject]@{ Category = 'Software and Utility'; Version = '7.13.0'; Title = 'WinRAR v7.13.0'; Date = '2025/08/27' },
    [pscustomobject]@{ Category = 'VGA Drivers'; Version = '31.0.21924.61'; Title = 'AMD VGA driver'; Date = '2026/04/28' })
$latest = Get-BoardDriverLatest $listing
Check 'listing: utilities and VGA ignored' (@($latest | Where-Object { $_.Category -notin 'LAN', 'Audio', 'Wireless', 'Bluetooth' }).Count) 0
Check 'listing: newest audio' ($latest | Where-Object { $_.Category -eq 'Audio' }).Version '6.0.9700.1'
Check 'listing: intel chip' ($latest | Where-Object { $_.Vendor -eq 'Intel' }).Chip 'I211'
Check 'listing: windows "11" is not a chip' ($latest | Where-Object { $_.Category -eq 'Audio' }).Chip ''
$pc = @(
    [pscustomobject]@{ DeviceName = 'Realtek Gaming 2.5GbE Family Controller'; DeviceClass = 'NET'; Manufacturer = 'Realtek'; DriverProviderName = 'Realtek' },
    [pscustomobject]@{ DeviceName = 'Intel(R) I211 Gigabit Network Connection'; DeviceClass = 'NET'; Manufacturer = 'Intel'; DriverProviderName = 'Microsoft' },
    [pscustomobject]@{ DeviceName = 'MediaTek Wi-Fi 6E MT7922 160MHz Wireless LAN Card'; DeviceClass = 'NET'; Manufacturer = 'MediaTek, Inc.'; DriverProviderName = 'MediaTek, Inc.' },
    [pscustomobject]@{ DeviceName = 'MediaTek Bluetooth Adapter'; DeviceClass = 'BLUETOOTH'; Manufacturer = 'MediaTek, Inc.'; DriverProviderName = 'MediaTek, Inc.' },
    [pscustomobject]@{ DeviceName = 'Bluetooth Device (RFCOMM Protocol TDI)'; DeviceClass = 'BLUETOOTH'; Manufacturer = 'Microsoft'; DriverProviderName = 'Microsoft' },
    [pscustomobject]@{ DeviceName = 'Realtek(R) Audio'; DeviceClass = 'MEDIA'; Manufacturer = 'Realtek'; DriverProviderName = 'Realtek Semiconductor Corp.' },
    [pscustomobject]@{ DeviceName = 'AMD High Definition Audio Device'; DeviceClass = 'MEDIA'; Manufacturer = 'Advanced Micro Devices'; DriverProviderName = 'Advanced Micro Devices' })
function M($cat, $vendor) { $g = $latest | Where-Object { $_.Category -eq $cat -and $_.Vendor -eq $vendor } | Sort-Object { ConvertTo-Ver $_.Version } -Descending | Select-Object -First 1; @(Find-BoardDriverMatch $g $pc) }
Check 'match audio to Realtek only' ((M 'Audio' 'Realtek') | ForEach-Object { $_.DeviceName }) 'Realtek(R) Audio'
Check 'match intel LAN by chip' ((M 'LAN' 'Intel') | ForEach-Object { $_.DeviceName }) 'Intel(R) I211 Gigabit Network Connection'
Check 'match wifi, not wired or bluetooth' ((M 'Wireless' 'MediaTek') | ForEach-Object { $_.DeviceName }) 'MediaTek Wi-Fi 6E MT7922 160MHz Wireless LAN Card'
Check 'match bluetooth adapter, not Microsoft stack' ((M 'Bluetooth' 'MediaTek') | ForEach-Object { $_.DeviceName }) 'MediaTek Bluetooth Adapter'
# "Realtek LAN Driver" and "Realtek RTL8125 LAN driver" are the same chip: one group, newest version, matched by vendor
Check 'unnamed entries adopt the only named chip' (@($latest | Where-Object { $_.Category -eq 'LAN' -and $_.Vendor -eq 'Realtek' }).Count) 1
Check 'merged Realtek LAN is newest' ($latest | Where-Object { $_.Category -eq 'LAN' -and $_.Vendor -eq 'Realtek' }).Version '1125.27.50.919'
Check 'Realtek LAN matched though device name has no chip' ((M 'LAN' 'Realtek') | ForEach-Object { $_.DeviceName }) 'Realtek Gaming 2.5GbE Family Controller'
# two differently named chips from one vendor: a device whose name shows neither is not guessed
$two = Get-BoardDriverLatest @(
    [pscustomobject]@{ Category = 'LAN'; Version = '1125.27.50.919'; Title = 'Realtek RTL8125 LAN driver'; Date = '' },
    [pscustomobject]@{ Category = 'LAN'; Version = '10.72.524.2024'; Title = 'Realtek RTL8168 LAN driver'; Date = '' })
Check 'two named chips stay separate' @($two).Count 2
Check 'ambiguous device is not guessed' (@($two | ForEach-Object { Find-BoardDriverMatch $_ $pc }).Count) 0

Write-Host ('{0} passed, {1} failed' -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
exit $script:Fail
