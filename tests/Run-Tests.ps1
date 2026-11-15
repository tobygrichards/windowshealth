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

# ---- regression: no blue-screen records at all (this emptied the Crashes section on a real PC)
Check 'nearest record with no records does not throw' ($null -eq (Select-NearestRecord $null $t0 @{} 2 30)) $true
Check 'nearest record with empty list' ($null -eq (Select-NearestRecord @() $t0 @{} 2 30)) $true

# ---- power losses
$alive = [datetime]'2026-11-10 23:30:00'; $boot = [datetime]'2026-11-10 09:00:00'
Check 'state: in use' (Get-PowerLossState $alive $boot @() @() @()) 'in-use'
Check 'state: asleep' (Get-PowerLossState $alive $boot @($alive.AddMinutes(-1)) @() @()) 'asleep'
Check 'state: woke again after sleeping is in use' (Get-PowerLossState $alive $boot @($alive.AddHours(-5)) @($alive.AddHours(-4)) @()) 'in-use'
Check 'state: slept, woke, slept again' (Get-PowerLossState $alive $boot @($alive.AddHours(-5), $alive.AddMinutes(-2)) @($alive.AddHours(-4)) @()) 'asleep'
Check 'state: sleep from an earlier session is ignored' (Get-PowerLossState $alive $boot @($boot.AddHours(-3)) @() @()) 'in-use'
Check 'state: shutting down' (Get-PowerLossState $alive $boot @() @() @($alive.AddMinutes(-1))) 'shutting-down'
Check 'state: old shutdown request ignored' (Get-PowerLossState $alive $boot @() @() @($alive.AddHours(-2))) 'in-use'
Check 'state: starting up' (Get-PowerLossState $boot.AddMinutes(2) $boot @() @() @()) 'starting-up'
Check 'state: unknown session start is in use' (Get-PowerLossState $alive $null @() @() @()) 'in-use'
Check 'state: empty lists passed as null' (Get-PowerLossState $alive $boot $null $null $null) 'in-use'
Check 'duration minutes' (Format-Duration 12) '12 min'
Check 'duration hours' (Format-Duration 200) '3 h 20 min'
Check 'duration days' (Format-Duration 3000) '2 d 2 h'
Check 'description names no component' ((Get-PowerLossDescription 'asleep')[1] -match 'PSU|power supply') $false

# a component is only named when the report holds evidence for it
$s1 = Get-PowerLossSummary @('asleep', 'asleep', 'shutting-down') $false 0 0 $false
Check 'asleep only: informational' $s1.Sev 'info'
Check 'asleep only: PSU not suspected' ($s1.PsuTitle -match 'suspect') $false
Check 'asleep only: PSU informational' $s1.PsuSev 'info'
$s2 = Get-PowerLossSummary @('in-use', 'in-use', 'in-use', 'asleep') $false 0 0 $false
Check 'in use x3: critical in Crashes' $s2.Sev 'crit'
Check 'in use, no evidence: PSU NOT named a suspect' ($s2.PsuTitle -match 'credible suspect') $false
Check 'in use, no evidence: PSU section is not a warning' $s2.PsuSev 'info'
Check 'in use, no evidence: says no component is named' ($s2.Detail -match 'no evidence pointing at any one component') $true
Check 'in use, no sensors: action says get sensors working' ($s2.Action -match 'get the sensors working') $true
Check 'in use: counts only running losses in the title' ($s2.Title -match '^3 unexpected') $true
$s3 = Get-PowerLossSummary @('in-use') $true 0 0 $true
Check 'in use + rail evidence: PSU named' ($s3.PsuTitle -match 'credible suspect') $true
Check 'in use + rail evidence: PSU warning' $s3.PsuSev 'warn'
Check 'one loss in use: warning not critical' $s3.Sev 'warn'
$s4 = Get-PowerLossSummary @('in-use', 'in-use') $false 2 0 $true
Check 'hardware errors named, PSU not' (($s4.Detail -match 'CPU or memory') -and -not ($s4.PsuTitle -match 'credible suspect')) $true
$s5 = Get-PowerLossSummary @('asleep') $true 0 0 $true
Check 'rail evidence but only asleep losses: PSU not tied to them' ($s5.PsuTitle -match 'credible suspect') $false

# ---- SSD life: the figures from a real report (SATA drives publish remaining "Life", not "Percentage Used")
function Lv($name, $v) { [pscustomobject]@{ Type = 'Level'; Name = $name; Value = [double]$v } }
Check 'life used: SATA "Life" 81 means 19 used' (Get-DriveLifeUsed @((Lv 'Life' 81)) 0 'SATA') 19
Check 'life used: "Remaining Life"' (Get-DriveLifeUsed @((Lv 'Remaining Life' 88)) 0 'SATA') 12
Check 'life used: NVMe percentage used wins' (Get-DriveLifeUsed @((Lv 'Life' 96), (Lv 'Percentage Used' 4)) 0 'NVMe') 4
Check 'life used: "Available Spare" is not life' ($null -eq (Get-DriveLifeUsed @((Lv 'Available Spare' 100)) $null 'NVMe')) $true
Check 'life used: Windows 0 on SATA is not trusted' ($null -eq (Get-DriveLifeUsed @() 0 'SATA')) $true
Check 'life used: Windows value on NVMe is used' (Get-DriveLifeUsed @() 3 'NVMe') 3
Check 'life used: nothing reported' ($null -eq (Get-DriveLifeUsed @() $null 'SATA')) $true
Check 'drive age note at 47,645 h' ((Get-DriveAgeNote 47645) -match '5\.4 years') $true
Check 'no drive age note at 7,809 h' (Get-DriveAgeNote 7809) ''

# ---- free space (figures from the same report)
Check 'space: 282 GB free of 3.64 TB system drive is fine' (Get-FreeSpaceSeverity 282GB 3.64TB $true) 'ok'
Check 'space: 44 GB free of 931 GB data drive is a warning, not critical' (Get-FreeSpaceSeverity 44GB 931GB $false) 'warn'
Check 'space: system drive under 10 GB is critical' (Get-FreeSpaceSeverity 6GB 500GB $true) 'crit'
Check 'space: system drive under 25 GB warns' (Get-FreeSpaceSeverity 20GB 500GB $true) 'warn'
Check 'space: data drive never critical' (Get-FreeSpaceSeverity 1GB 500GB $false) 'warn'
Check 'space: half-full data drive' (Get-FreeSpaceSeverity 236GB 466GB $false) 'ok'

# ---- memory maker
Check 'maker from Corsair part number' (Get-MemoryMaker 'Unknown' 'CMK64GX4M2D3600C18') 'Corsair'
Check 'maker from G.Skill part number' (Get-MemoryMaker '' 'F4-3600C16-16GTZN') 'G.Skill'
Check 'reported maker kept' (Get-MemoryMaker 'Kingston' 'CMK64') 'Kingston'
Check 'maker unknown' (Get-MemoryMaker 'Unknown' 'XYZ123') 'Not reported'

# ---- updates and offers
Check 'defender definitions are routine' (Test-RoutineUpdate 'Security Intelligence Update for Microsoft Defender Antivirus - KB2267602 (Version 1.4)') $true
Check 'cumulative update is not routine' (Test-RoutineUpdate '2026-11 Cumulative Update for Windows 11 (KB5132061)') $false
Check 'recent gpu driver behind is a note' (Get-GpuDriverSeverity 19) 'info'
Check 'old gpu driver behind is a warning' (Get-GpuDriverSeverity 200) 'warn'
Check 'version from title' (Get-VersionFromTitle 'NVIDIA Display Driver Update (32.0.16.1088)') '32.0.16.1088'
Check 'no version in title' (Get-VersionFromTitle 'Logitech Extension Driver Update') ''
$inst = @(
    [pscustomobject]@{ DeviceName = 'Realtek High Definition Audio'; DeviceClass = 'MEDIA'; Manufacturer = 'Realtek'; DriverProviderName = 'Realtek Semiconductor Corp.'; DriverDate = [datetime]'2026-04-14' },
    [pscustomobject]@{ DeviceName = 'NVIDIA High Definition Audio'; DeviceClass = 'MEDIA'; Manufacturer = 'NVIDIA'; DriverProviderName = 'NVIDIA Corporation'; DriverDate = [datetime]'2026-08-25' },
    [pscustomobject]@{ DeviceName = 'NVIDIA Virtual Audio Device (Wave Extensible) (WDM)'; DeviceClass = 'MEDIA'; Manufacturer = 'NVIDIA'; DriverProviderName = 'NVIDIA'; DriverDate = [datetime]'2026-04-08' },
    [pscustomobject]@{ DeviceName = 'Parsec Virtual Display Adapter'; DeviceClass = 'DISPLAY'; Manufacturer = 'Parsec'; DriverProviderName = 'Parsec Cloud, Inc.'; DriverDate = [datetime]'2024-01-25' },
    [pscustomobject]@{ DeviceName = 'Realtek PCIe GbE Family Controller'; DeviceClass = 'NET'; Manufacturer = 'Realtek'; DriverProviderName = 'Realtek'; DriverDate = [datetime]'2025-03-10' })
Check 'offer target: 2016 Realtek sound offer maps to installed Realtek audio' (Find-OfferedDriverTarget 'Realtek Semiconductor Corp. - MEDIA - 6/3/2016 12:00:00 AM - 6.0.1.7841' 'Sound' $inst).DeviceName 'Realtek High Definition Audio'
Check 'offer target: by class when title has no class' (Find-OfferedDriverTarget 'NVIDIA Display Driver Update (32.0.16.1088)' 'Display' $inst | Measure-Object).Count 0
Check 'offer target: unknown vendor' ($null -eq (Find-OfferedDriverTarget 'Logitech Extension Driver Update (2.0.998.0)' 'Extension' $inst)) $true
Check 'offer target: unsupported class' ($null -eq (Find-OfferedDriverTarget 'Micro-Star INT''L CO., LTD. System Driver Update (1.0.0.16)' 'OtherHardware' $inst)) $true
Check 'virtual: Parsec display' (Test-VirtualDevice $inst[3]) $true
Check 'virtual: real network card is not' (Test-VirtualDevice $inst[4]) $false
Check 'virtual: audio class is not listed' (Test-VirtualDevice $inst[2]) $false

# ---- comparing two runs (snapshots are read back from JSON, as they are in real use)
function Snap($h) { return ($h | ConvertTo-Json -Depth 8 | ConvertFrom-Json) }
$before = @{
    generated = '2026-11-01 10:00'; bios = '5044'; build = '26200.9974'
    incidents = @('2026-10-28 14:00|Power lost while in use'); whea = @(); tdr = @()
    drives = @{ 'S1' = @{ name = 'Samsung 990 PRO'; lifeUsed = 4; writtenGB = 60000; hours = 7800; uncorrected = 0; health = 'Healthy' }
                'S2' = @{ name = 'Old SSD'; lifeUsed = 19; writtenGB = 99000; hours = 38000; uncorrected = 0; health = 'Healthy' } }
    drivers = @{ 'Realtek Audio' = '6.0.9700.1'; 'NVIDIA GeForce RTX 5070 Ti' = '32.0.16.2114'; 'Realtek LAN' = '10.79.50.1003' }
    rails = @{ '+12V' = 12.10 }
    findings = @(@{ key = (Get-FindingKey 'drives' 'Volume F: is nearly full: 44 GB free (5 %)'); title = 'Volume F: is nearly full'; area = 'Drives' },
                 @{ key = (Get-FindingKey 'windows' 'Windows component store is damaged (Repairable)'); title = 'Windows component store is damaged'; area = 'Windows' })
}
$same = Compare-Snapshots (Snap $before) (Snap $before)
Check 'identical runs: one all-clear' @($same.Findings).Count 1
Check 'identical runs: all-clear is ok' $same.Findings[0].sev 'ok'
Check 'identical runs: no driver changes' @($same.DriverChanges).Count 0

$after = @{
    generated = '2026-11-15 10:00'; bios = '5220'; build = '26200.9974'
    incidents = @('2026-10-28 14:00|Power lost while in use', '2026-11-10 21:30|Power lost while in use', '2026-10-20 09:00|Blue screen')
    whea = @('2026-11-10 21:31|WHEA 18'); tdr = @()
    drives = @{ 'S1' = @{ name = 'Samsung 990 PRO'; lifeUsed = 5; writtenGB = 63000; hours = 8100; uncorrected = 3; health = 'Healthy' }
                'S3' = @{ name = 'New NVMe'; lifeUsed = 0; writtenGB = 10; hours = 5; uncorrected = 0; health = 'Healthy' } }
    drivers = @{ 'Realtek Audio' = '6.0.9411.1'; 'NVIDIA GeForce RTX 5070 Ti' = '32.0.16.2200'; 'Realtek LAN' = '10.79.50.1003'; 'New Device' = '1.0' }
    rails = @{ '+12V' = 11.70 }
    findings = @(@{ key = (Get-FindingKey 'drives' 'Volume F: is nearly full: 31 GB free (3 %)'); title = 'Volume F: is nearly full'; area = 'Drives' },
                 @{ key = (Get-FindingKey 'cpu' '1 fatal machine-check error(s) logged'); title = '1 fatal machine-check error(s) logged'; area = 'CPU' })
}
$cmp = Compare-Snapshots (Snap $before) (Snap $after)
function HasChange($sev, $pattern) { [bool](@($cmp.Findings | Where-Object { $_.sev -eq $sev -and $_.title -match $pattern }).Count) }
Check 'days between runs' ([math]::Round($cmp.Days)) 14
Check 'one new incident (old-window blue screen and the known one are not counted)' (HasChange 'warn' '^1 new crash or unexpected power loss') $true
Check 'new hardware error record' (HasChange 'warn' '^1 new hardware error record') $true
Check 'uncorrected errors rose' (HasChange 'warn' 'uncorrected errors rose from 0 to 3') $true
Check 'life used rose by one point is a note' (HasChange 'info' 'rated life used rose from 4 % to 5 %') $true
Check 'high write rate noted' (HasChange 'info' '3,000 GB written since the last run, about 214 GB a day') $true
Check 'drive vanished' (HasChange 'warn' 'Drive no longer detected: Old SSD') $true
Check 'new drive' (HasChange 'info' 'New drive detected: New NVMe') $true
Check 'driver downgrade is a warning' (HasChange 'warn' '^1 driver\(s\) were replaced with an OLDER version') $true
Check 'driver update is a note' (HasChange 'info' '^1 driver\(s\) were updated') $true
Check 'driver change table has both' @($cmp.DriverChanges).Count 2
Check 'unchanged and new drivers are not listed as changes' (@($cmp.DriverChanges | Where-Object { $_[0] -in 'Realtek LAN', 'New Device' }).Count) 0
Check 'BIOS change' (HasChange 'info' 'BIOS changed from 5044 to 5220') $true
Check 'build unchanged is silent' (HasChange 'info' 'Windows build changed') $false
Check 'rail drift' (HasChange 'info' '\+12V rail reads 11\.70 V; it read 12\.10 V') $true
Check 'same finding with different numbers is not new' (@($cmp.Findings | Where-Object { $_.detail -match 'Volume F' }).Count) 0
Check 'new problem reported' (HasChange 'warn' '^1 problem\(s\) reported now that were not reported last time') $true
Check 'resolved problem reported' (HasChange 'ok' '^1 problem\(s\) from last time are no longer reported') $true
Check 'no all-clear when things got worse' (HasChange 'ok' 'Nothing has got worse') $false
# a report from before this feature has none of the fields
$empty = Compare-Snapshots (Snap @{ generated = '2026-11-01 10:00' }) (Snap $after)
Check 'old-format previous run does not throw' (@($empty.Findings).Count -gt 0) $true

# ---- board maker support pages
Check 'MSI support page' (Get-BoardSupportUrl 'Micro-Star International Co., Ltd' 'B450 TOMAHAWK MAX (MS-7C02)' 'AMD Ryzen 9 5900X') 'https://www.msi.com/Motherboard/B450-TOMAHAWK-MAX/support'
Check 'ASRock support page' (Get-BoardSupportUrl 'ASRock' 'B550 Steel Legend' 'AMD Ryzen 5 5600X') 'https://www.asrock.com/mb/AMD/B550%20Steel%20Legend/index.asp#Download'
Check 'ASRock Intel platform' ((Get-BoardSupportUrl 'ASRock' 'Z790 Pro RS' 'Intel(R) Core(TM) i7-13700K') -match '/mb/Intel/') $true
Check 'Gigabyte search page' (Get-BoardSupportUrl 'Gigabyte Technology Co., Ltd.' 'B650 AORUS ELITE AX' 'AMD') 'https://www.gigabyte.com/Search?kw=B650%20AORUS%20ELITE%20AX'
Check 'unknown maker' (Get-BoardSupportUrl 'Dell Inc.' '0XYZ' 'Intel') ''
Check 'board devices: sound and LAN, not GPU audio or virtual' ((Select-BoardDeviceDrivers $inst | ForEach-Object { $_.DeviceName }) -join ',') 'Realtek High Definition Audio,Realtek PCIe GbE Family Controller'

# ---- Windows' repair log (CBS.log)
function CbsBlock($time, $op, $detected, $repaired, $items, $failed) {
    $l = @("$time, Info                  CBS    Checking System Update Readiness.")
    foreach ($i in $items) { $l += "$time, Info                  CBS    (p)`tCSI Payload Corrupt`t(n)`t`t`t$i" }
    foreach ($x in $failed) { $l += "$time, Info                  CBS    Repair failed: $x" }
    $l += "$time, Info                  CBS    Summary:"
    $l += "$time, Info                  CBS    Operation: $op "
    $l += "$time, Info                  CBS    Operation result: 0x0"
    $l += "$time, Info                  CBS    Total Detected Corruption:`t$detected"
    $l += "$time, Info                  CBS    `tCSI Payload Corruption:`t$detected"
    $l += "$time, Info                  CBS    Total Repaired Corruption:`t$repaired"
    $l += "$time, Info                  CBS    Total Operation Time: 80 seconds."
    return $l
}
$item = 'amd64_microsoft-windows-foo_31bf3856ad364e35_10.0.26300.1_none_abc\foo.dll'
$logA = @('2026-11-15 15:00:00, Info                  CBS    unrelated line') +
    (CbsBlock '2026-11-15 15:10:00' 'Detect and Repair' 2 0 @($item, 'amd64_bar_1\bar.dll') @('Missing replacement payload.', 'Missing replacement payload.')) +
    (CbsBlock '2026-11-15 15:42:00' 'Detect only' 2 0 @($item) @())
$sa = Get-CbsRepairSessions $logA
Check 'cbs: two sessions parsed' @($sa).Count 2
Check 'cbs: operation' $sa[0].Operation 'Detect and Repair'
Check 'cbs: detected' $sa[0].Detected 2
Check 'cbs: repaired' $sa[0].Repaired 0
Check 'cbs: corrupt item named' ($sa[0].Items[0] -match 'CSI Payload Corrupt: amd64_microsoft-windows-foo') $true
Check 'cbs: repair failure reason' $sa[0].Failed[0] 'Missing replacement payload.'
Check 'cbs: time' $sa[1].When '2026-11-15 15:42'
$va = Get-CbsRepairVerdict $sa
Check 'cbs verdict: repair could not fix' ($va.Title -match 'could not fix 2 of 2') $true
Check 'cbs verdict: says repeating will not help' ($va.Action -match 'Repeating the same command will not help') $true
Check 'cbs verdict: reason included' ($va.Detail -match 'Missing replacement payload') $true
$vb = Get-CbsRepairVerdict (Get-CbsRepairSessions ((CbsBlock '2026-11-15 15:10:00' 'Detect and Repair' 1 1 @($item) @()) + (CbsBlock '2026-11-15 15:42:00' 'Detect only' 1 0 @($item) @())))
Check 'cbs verdict: repaired but found again' ($vb.Title -match 'later scan found the damage again') $true
$vc = Get-CbsRepairVerdict (Get-CbsRepairSessions (CbsBlock '2026-11-15 15:42:00' 'Detect only' 1 0 @($item) @()))
Check 'cbs verdict: no repair recorded' ($vc.Title -match 'no repair attempt') $true
$vd2 = Get-CbsRepairVerdict (Get-CbsRepairSessions (CbsBlock '2026-11-15 15:10:00' 'Detect and Repair' 1 1 @($item) @()))
Check 'cbs verdict: repair fixed everything' ($vd2.Title -match 'fixed everything') $true
Check 'cbs verdict: empty log' ($null -eq (Get-CbsRepairVerdict (Get-CbsRepairSessions @('nothing', $null)))) $true
Check 'cbs: unfinished session is ignored' @(Get-CbsRepairSessions @('2026-11-15 15:10:00, Info                  CBS    Checking System Update Readiness.')).Count 0

Write-Host ('{0} passed, {1} failed' -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
exit $script:Fail
