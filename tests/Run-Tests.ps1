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

Write-Host ('{0} passed, {1} failed' -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
exit $script:Fail
