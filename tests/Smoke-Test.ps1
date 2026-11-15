# Smoke test: runs the whole of Get-PCHealth.ps1 against a simulated PC, on any OS with PowerShell 7.
#   pwsh -File tests/Smoke-Test.ps1
# Windows-only cmdlets are replaced with stand-ins that return a small fake machine, the elevation
# prompt is skipped and fake sensor readings are injected. It proves the collector runs from start to
# finish without a script error and produces a dashboard; it does not prove the real Windows queries
# return what is expected. Exit code 0 = pass.
param([string]$OutDir = (Join-Path ([IO.Path]::GetTempPath()) 'pchealth-smoke'), [switch]$Online)

$root = Split-Path -Parent $PSScriptRoot
$src = Get-Content (Join-Path $root 'Get-PCHealth.ps1') -Raw

# 1. skip elevation (needs Windows) and pretend to be an administrator
$a = $src.IndexOf('# ---------------------------------------------------------------- elevation')
$b = $src.IndexOf('try { [Net.ServicePointManager]')
if ($a -lt 0 -or $b -lt 0) { Write-Host 'FAIL: elevation section markers not found'; exit 1 }
$src = $src.Substring(0, $a) + "`$IsAdmin = `$true`n" + $src.Substring($b)

# 2. inject fake sensors where the script would report "sensors disabled"
$marker = "    `$script:SensorNote = 'Sensors disabled with -NoSensors.'"
if (-not $src.Contains($marker)) { Write-Host 'FAIL: sensor marker not found'; exit 1 }
$src = $src.Replace($marker, '    foreach ($f in $global:FakeSensors) { [void]$script:Sensors.Add($f) }; $script:SensorSource = ''simulated''')
$src = $src.Replace('$PSScriptRoot', '$global:ToolRoot')
$global:ToolRoot = $root

function New-FakeSensor($hw, $hwType, $id, $type, $name, $value) {
    [pscustomobject]@{ Hw = $hw; HwType = $hwType; Id = $id; Name = $name; Type = $type; Value = [double]$value; Min = [double]$value; Max = [double]$value; Valid = $true; Note = ''; Step = 0.0 }
}
$global:FakeSensors = @(
    (New-FakeSensor 'AMD Ryzen 9 5950X' 'Cpu' '/amdcpu/0' 'Temperature' 'Core (Tctl/Tdie)' 62),
    (New-FakeSensor 'AMD Ryzen 9 5950X' 'Cpu' '/amdcpu/0' 'Voltage' 'Core (SVI2 TFN)' 1.41),
    (New-FakeSensor 'AMD Radeon RX 9070 XT' 'GpuAmd' '/gpu-amd/0' 'Temperature' 'GPU Core' 55),
    (New-FakeSensor 'AMD Radeon RX 9070 XT' 'GpuAmd' '/gpu-amd/0' 'Temperature' 'GPU Hot Spot' 71),
    (New-FakeSensor 'Embedded Controller' 'EmbeddedController' '/lpc/ec' 'Temperature' 'Chipset' 49),
    (New-FakeSensor 'Embedded Controller' 'EmbeddedController' '/lpc/ec' 'Temperature' 'VRM' 104),
    (New-FakeSensor 'Nuvoton NCT6798D' 'SuperIO' '/lpc/nct6798d' 'Temperature' 'CPU' 58),
    (New-FakeSensor 'Nuvoton NCT6798D' 'SuperIO' '/lpc/nct6798d' 'Temperature' 'Temperature #6' 92),
    (New-FakeSensor 'Nuvoton NCT6798D' 'SuperIO' '/lpc/nct6798d' 'Voltage' '+12V' 10.9),
    (New-FakeSensor 'Nuvoton NCT6798D' 'SuperIO' '/lpc/nct6798d' 'Voltage' '3VCC' 3.31),
    (New-FakeSensor 'Nuvoton NCT6798D' 'SuperIO' '/lpc/nct6798d' 'Voltage' 'VBAT' 3.1),
    (New-FakeSensor 'Samsung SSD 990 PRO 1TB' 'Storage' '/nvme/0' 'Data' 'Data Written' 4116),
    (New-FakeSensor 'Samsung SSD 990 PRO 1TB' 'Storage' '/nvme/0' 'Level' 'Percentage Used' 0),
    (New-FakeSensor 'Samsung SSD 990 PRO 1TB' 'Storage' '/nvme/0' 'Temperature' 'Warning Temperature' 82),
    (New-FakeSensor 'Samsung SSD 990 PRO 1TB' 'Storage' '/nvme/2' 'Data' 'Data Written' 550000),
    (New-FakeSensor 'Samsung SSD 990 PRO 1TB' 'Storage' '/nvme/2' 'Level' 'Percentage Used' 93)
)

# 3. stand-ins for Windows-only cmdlets
$global:AudioVersion = '6.0.9000.1'
$global:BoardMaker = 'ASUSTeK COMPUTER INC.'; $global:BoardProduct = 'ROG STRIX X570-E GAMING WIFI II'
function global:Get-CimInstance {
    param($ClassName, $Namespace, $Filter, $ErrorAction)
    switch ($ClassName) {
        'Win32_Processor' { [pscustomobject]@{ Name = 'AMD Ryzen 9 5950X 16-Core Processor'; NumberOfCores = 16; NumberOfLogicalProcessors = 32; SocketDesignation = 'AM4'; MaxClockSpeed = 3400; LoadPercentage = 7 } }
        'Win32_VideoController' { [pscustomobject]@{ Name = 'AMD Radeon RX 9070 XT'; PNPDeviceID = 'PCI\VEN_1002'; DriverVersion = '32.0.31044.16'; DriverDate = (Get-Date).AddDays(-30); VideoModeDescription = '2560 x 1440'; Status = 'OK'; ConfigManagerErrorCode = 0 } }
        'Win32_OperatingSystem' { [pscustomobject]@{ Caption = 'Microsoft Windows 11 Pro'; BuildNumber = '26200'; InstallDate = (Get-Date).AddDays(-28); LastBootUpTime = (Get-Date).AddHours(-5); TotalVisibleMemorySize = 33554432; FreePhysicalMemory = 16777216 } }
        'Win32_BaseBoard' { [pscustomobject]@{ Manufacturer = $global:BoardMaker; Product = $global:BoardProduct; Version = 'Rev X.0x' } }
        'Win32_BIOS' { [pscustomobject]@{ SMBIOSBIOSVersion = '5044'; ReleaseDate = (Get-Date).AddMonths(-10) } }
        'Win32_ComputerSystem' { [pscustomobject]@{ Manufacturer = 'System manufacturer'; Model = 'System Product Name' } }
        'Win32_PhysicalMemory' { [pscustomobject]@{ DeviceLocator = 'DIMM_A2'; Capacity = 17179869184; Manufacturer = 'G.Skill'; PartNumber = 'F4-3600C16'; Speed = 3600; ConfiguredClockSpeed = 2133 } }
        'Win32_PnPSignedDriver' {
            [pscustomobject]@{ DeviceName = 'AMD Radeon RX 9070 XT'; DeviceClass = 'DISPLAY'; DriverProviderName = 'Advanced Micro Devices, Inc.'; Manufacturer = 'Advanced Micro Devices, Inc.'; DriverVersion = '32.0.31044.16'; DriverDate = (Get-Date).AddDays(-30); IsSigned = $true; InfName = 'oem42.inf' }
            [pscustomobject]@{ DeviceName = 'Realtek Audio'; DeviceClass = 'MEDIA'; DriverProviderName = 'Realtek'; Manufacturer = 'Realtek'; DriverVersion = $global:AudioVersion; DriverDate = (Get-Date).AddYears(-5); IsSigned = $true; InfName = 'hdaudio.inf' }
            [pscustomobject]@{ DeviceName = 'Realtek Gaming 2.5GbE Family Controller'; DeviceClass = 'NET'; DriverProviderName = 'Realtek'; Manufacturer = 'Realtek'; DriverVersion = '1125.99.1.1'; DriverDate = (Get-Date).AddDays(-10); IsSigned = $true; InfName = 'oem7.inf' }
        }
        'Win32_Service' { if ($Namespace) { throw 'Invalid namespace' } }
        default { if ($ErrorAction -eq 'Stop' -and $ClassName -match 'Battery|FailurePredict|AntiVirus') { throw 'Invalid class' } }
    }
}
# A small event log: three sessions, each ending without a clean shutdown and with NO blue-screen record.
#   1. lost power while in use   2. lost power while asleep   3. lost power during a requested shutdown
function New-FakeEvent($provider, $id, [datetime]$time, $value) {
    [pscustomobject]@{ ProviderName = $provider; Id = $id; TimeCreated = $time; RecordId = [int64]($time.Ticks % 1000000007); Level = 4; Message = "event $id"; Properties = @([pscustomobject]@{ Value = $value }) }
}
$d0 = (Get-Date).Date.AddDays(-10)
$KG = 'Microsoft-Windows-Kernel-General'; $KP = 'Microsoft-Windows-Kernel-Power'
$global:FakeEvents = @(
    (New-FakeEvent $KG 12 $d0.AddHours(9) 0),                              # session 1 starts
    (New-FakeEvent 'Service Control Manager' 7036 $d0.AddHours(14) 0),      # last sign of life, in use
    (New-FakeEvent $KG 12 $d0.AddHours(14).AddMinutes(2) 0),                # back on 2 minutes later
    (New-FakeEvent $KP 41 $d0.AddHours(14).AddMinutes(2).AddSeconds(20) 0),
    (New-FakeEvent $KP 42 $d0.AddHours(23) 0),                              # session 2 goes to sleep
    (New-FakeEvent $KG 12 $d0.AddDays(1).AddHours(8) 0),                    # started cold next morning
    (New-FakeEvent $KP 41 $d0.AddDays(1).AddHours(8).AddSeconds(20) 0),
    (New-FakeEvent 'User32' 1074 $d0.AddDays(1).AddHours(22) 0),            # session 3: shutdown requested
    (New-FakeEvent $KG 12 $d0.AddDays(2).AddHours(9) 0),
    (New-FakeEvent $KP 41 $d0.AddDays(2).AddHours(9).AddSeconds(20) 0))
function global:Get-WinEvent {
    param($FilterHashtable, $MaxEvents, $ErrorAction)
    $f = $FilterHashtable
    $r = @($global:FakeEvents | Where-Object {
            (-not $f.ProviderName -or $_.ProviderName -eq $f.ProviderName) -and (-not $f.Id -or $_.Id -in $f.Id) -and
            (-not $f.StartTime -or $_.TimeCreated -ge $f.StartTime) -and (-not $f.EndTime -or $_.TimeCreated -le $f.EndTime) } | Sort-Object TimeCreated -Descending)
    if ($MaxEvents) { $r = @($r | Select-Object -First $MaxEvents) }
    if ($r.Count -eq 0) { Write-Error -Message 'No events were found' -ErrorId 'NoMatchingEventsFound' -ErrorAction Stop }
    $r
}
function global:Get-PhysicalDisk {
    [pscustomobject]@{ FriendlyName = 'Samsung SSD 990 PRO 1TB'; DeviceId = '0'; MediaType = 'SSD'; BusType = 'NVMe'; Size = 1TB; HealthStatus = 'Healthy'; OperationalStatus = 'OK'; FirmwareVersion = '4B2QJXD7' }
    [pscustomobject]@{ FriendlyName = 'Samsung SSD 990 PRO 1TB'; DeviceId = '2'; MediaType = 'SSD'; BusType = 'NVMe'; Size = 1TB; HealthStatus = 'Healthy'; OperationalStatus = 'OK'; FirmwareVersion = '4B2QJXD7' }
    [pscustomobject]@{ FriendlyName = 'ST2000DM008-2FR102'; DeviceId = '1'; MediaType = 'HDD'; BusType = 'SATA'; Size = 2TB; HealthStatus = 'Healthy'; OperationalStatus = 'OK'; FirmwareVersion = '0001' }
}
function global:Get-StorageReliabilityCounter { param([Parameter(ValueFromPipeline)]$d, $ErrorAction) process { [pscustomobject]@{ Wear = 0; Temperature = 34; PowerOnHours = 900; ReadErrorsUncorrected = 0; WriteErrorsUncorrected = 0 } } }
function global:Get-Volume { [pscustomobject]@{ DriveLetter = 'C'; Size = 600GB; SizeRemaining = 277GB; DriveType = 'Fixed'; FileSystemLabel = ''; FileSystem = 'NTFS'; HealthStatus = 'Healthy' } }
function global:Repair-WindowsImage { param([switch]$Online, [switch]$CheckHealth, [switch]$ScanHealth, $ErrorAction) if ($ScanHealth) { [pscustomobject]@{ ImageHealthState = 'Repairable' } } else { [pscustomobject]@{ ImageHealthState = 'Healthy' } } }
foreach ($n in 'Confirm-SecureBootUEFI', 'Get-Tpm', 'Get-HotFix', 'Get-MpComputerStatus', 'Get-WindowsDriver', 'Get-AppxPackage', 'Get-Service') {
    Set-Item -Path "function:global:$n" -Value { throw 'not available in the simulation' }
}

# 4. run it
Remove-Item $OutDir -Recurse -Force -ErrorAction SilentlyContinue
$script = [scriptblock]::Create($src)
$runErrors = @()
$net = @{ Offline = (-not $Online) }
try { & $script -NoSensors @net -NoOpen -OutDir $OutDir -ErrorVariable +runErrors *> (Join-Path ([IO.Path]::GetTempPath()) 'pchealth-smoke.log') }
catch { Write-Host ('FAIL: script threw: {0}' -f $_); Write-Host $_.ScriptStackTrace; exit 1 }

$json = Get-ChildItem $OutDir -Filter '*.json' -ErrorAction SilentlyContinue | Select-Object -First 1
$html = Get-ChildItem $OutDir -Filter '*.html' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $json -or -not $html) { Write-Host 'FAIL: no report was written'; Get-Content (Join-Path ([IO.Path]::GetTempPath()) 'pchealth-smoke.log') | Select-Object -Last 20; exit 1 }
$r = Get-Content $json.FullName -Raw | ConvertFrom-Json

$fail = 0
function Expect([string]$name, [bool]$cond) { if ($cond) { Write-Host ('ok    {0}' -f $name) } else { $script:fail++; Write-Host ('FAIL  {0}' -f $name) -ForegroundColor Red } }
function Area($id) { $r.areas | Where-Object { $_.id -eq $id } }
function Has($id, $sev, $pattern) { [bool](@((Area $id).findings | Where-Object { $_.sev -eq $sev -and $_.title -match $pattern }).Count) }

# steps that crash show up as collection notes starting with the step name
$stepCrashes = @($r.meta.errors | Where-Object { $_ -match '^(CPU|GPU|Memory|Drives|Power supply|Motherboard|Driver inventory|Crash analysis|Drivers):' })
Expect ('no collection step crashed' + $(if ($stepCrashes) { ': ' + ($stepCrashes -join ' | ') } else { '' })) ($stepCrashes.Count -eq 0)
Expect 'ten areas reported' (@($r.areas).Count -eq 10)
Expect 'first run says there is nothing to compare with' (Has 'changes' 'info' 'first run')
Expect 'dashboard embeds the data' ((Get-Content $html.FullName -Raw) -match '"computer"')
Expect 'CPU model collected' ([bool](@((Area 'cpu').facts | Where-Object { $_.v -match '5950X' }).Count))
Expect 'TjMax 90 used for 5950X' ([bool](@((Area 'cpu').facts | Where-Object { $_.k -match 'TjMax' -and $_.v -match '^90' }).Count))
Expect 'memory below rated speed noted' (Has 'memory' 'info' 'below its rated speed')
Expect 'VRM over range flagged on motherboard' (Has 'board' 'warn' 'VRM')
Expect 'unlabelled chip input explained, not judged' (Has 'board' 'info' 'unidentified sensor input')
Expect 'sagging 12 V rail from chip is a warning, not critical' ((Has 'psu' 'warn' '\+12V rail') -and -not (Has 'psu' 'crit' '\+12V'))
Expect 'PSU area is not Healthy' ((Area 'psu').status -eq 'warn')
$drv = (Area 'drives').tables | Where-Object { $_.title -eq 'Physical drives' }
Expect 'three drives listed' (@($drv.rows).Count -eq 3)
Expect 'twin drive 0 shows its own data written' ($drv.rows[0][6] -eq '4.1 TB')
Expect 'twin drive 2 shows its own data written' ($drv.rows[1][6] -eq '550.0 TB')
Expect 'worn twin drive flagged' (Has 'drives' 'crit' '93 % of its rated write endurance')
Expect 'hard disk has no life-used figure' ($drv.rows[2][5] -eq 'n/a (HDD)')
Expect 'services query does not fail' (@($r.meta.errors | Where-Object { $_ -match 'Win32_Service' }).Count -eq 0)
Expect 'machine summary in header' ($r.meta.machine -match '5950X' -and $r.meta.machine -match 'RX 9070 XT' -and $r.meta.machine -match 'X570')
Expect 'nearly full Windows drive not flagged when 277 GB is free' (-not (Has 'drives' 'warn' 'Volume C') -and -not (Has 'drives' 'crit' 'Volume C'))
$tl = (Area 'crash').tables | Where-Object { $_.title -match '^Timeline' }
Expect 'crash section is populated when there are power losses but no blue screens' (@($tl.rows).Count -eq 3)
Expect 'timeline: first loss was while in use, after 5 h' (($tl.rows[0][3].t -eq 'Power lost while in use') -and ($tl.rows[0][1] -eq '5 h 0 min') -and ($tl.rows[0][2] -eq '2 min'))
Expect 'timeline: second loss was while asleep' ($tl.rows[1][3].t -eq 'Power lost while asleep')
Expect 'timeline: third loss was during shutdown' ($tl.rows[2][3].t -eq 'Power lost during shutdown')
Expect 'timeline: no suspect named without a supporting event' (@($tl.rows | Where-Object { $_[5] -ne 'None indicated' }).Count -eq 0)
Expect 'crash finding counts only the loss while running' (Has 'crash' 'warn' '^1 unexpected power loss\(es\) while the PC was running \(of 3')
Expect 'PSU named a suspect because this simulated PC has an out-of-tolerance rail' (Has 'psu' 'warn' 'credible suspect')
Expect 'chipset package missing flagged' (Has 'drivers' 'warn' 'chipset driver package is not installed')
Expect 'overall is critical' ($r.meta.overall -eq 'crit')
$vs = (Area 'drivers').tables | Where-Object { $_.title -match '^Windows versus manufacturer' }
if ($Online) {
    # live lookups against AMD and ASUS: the simulated PC has a 5-year-old built-in Realtek audio driver
    Expect 'online: audio driver from Windows flagged as a CONFLICT' (Has 'drivers' 'warn' 'Realtek Audio: CONFLICT')
    Expect 'online: newer-than-listed LAN driver is not a conflict' (-not (Has 'drivers' 'warn' '2.5GbE'))
    Expect 'online: comparison table has GPU, chipset, audio, LAN and BIOS rows' (@($vs.rows).Count -ge 5)
    Expect 'online: BIOS compared' ([bool](@($vs.rows | Where-Object { $_[0] -eq 'Motherboard BIOS' }).Count))
    $vs.rows | ForEach-Object { Write-Host ('      {0} | {1} | {2} | {4} | {5}' -f $_[0], $_[1], $_[2], $_[3], $_[4], $(if ($_[5].t) { $_[5].t } else { $_[5] })) }
} else {
    Expect 'offline: comparison reported as not made, not as no conflict' (Has 'drivers' 'gap' 'No driver could be compared')
}

# 5. a second run in the same folder reports what changed since the first
$global:AudioVersion = '6.0.8000.1'                                        # audio driver replaced with an older one
($global:FakeSensors | Where-Object { $_.Id -eq '/nvme/0' -and $_.Name -eq 'Percentage Used' }).Value = 2   # wear moved on
$soon = (Get-Date).AddMinutes(5)                                            # a power loss after the first run
$global:FakeEvents += (New-FakeEvent 'Service Control Manager' 7036 $soon 0)
$global:FakeEvents += (New-FakeEvent $KG 12 $soon.AddMinutes(1) 0)
$global:FakeEvents += (New-FakeEvent $KP 41 $soon.AddMinutes(1).AddSeconds(20) 0)
$global:BoardMaker = 'Micro-Star International Co., Ltd'; $global:BoardProduct = 'B450 TOMAHAWK MAX (MS-7C02)'
Start-Sleep -Seconds 1
& $script -NoSensors -Offline -NoOpen -OutDir $OutDir *> $null
$r = Get-Content (Get-ChildItem $OutDir -Filter '*.json' | Sort-Object Name -Descending | Select-Object -First 1).FullName -Raw | ConvertFrom-Json
Expect 'second run: new power loss since last run' (Has 'changes' 'warn' '^1 new crash or unexpected power loss')
Expect 'second run: driver downgrade flagged' (Has 'changes' 'warn' 'replaced with an OLDER version')
Expect 'second run: drive wear increase noted' (Has 'changes' 'info' 'rated life used rose from 0 % to 2 %')
Expect 'second run: driver change table' (@(((Area 'changes').tables | Where-Object { $_.title -match 'changed version' }).rows).Count -eq 1)
Expect 'second run: unchanged problems are not reported as new' (-not (Has 'changes' 'warn' 'problem\(s\) reported now'))
Expect 'MSI board: not compared automatically, with the exact support page linked' ([bool](@((Area 'drivers').findings | Where-Object { $_.sev -eq 'gap' -and $_.title -match 'could not be compared automatically' -and $_.link -eq 'https://www.msi.com/Motherboard/B450-TOMAHAWK-MAX/support' }).Count))
Expect 'MSI board: compare-by-hand table lists audio, LAN and BIOS' (@(((Area 'drivers').tables | Where-Object { $_.title -match '^Compare by hand' }).rows).Count -eq 3)
$global:BoardMaker = 'ASUSTeK COMPUTER INC.'; $global:BoardProduct = 'ROG STRIX X570-E GAMING WIFI II'

# 6. deep scan finds the store damaged: the repair log explains why repairs have not fixed it
$fakeRoot = Join-Path ([IO.Path]::GetTempPath()) 'pchealth-fakewin'
New-Item -ItemType Directory -Path (Join-Path $fakeRoot 'Logs/CBS') -Force | Out-Null
$t1 = '2026-11-15 15:10:00, Info                  CBS    '; $t2 = '2026-11-15 15:42:00, Info                  CBS    '
@("${t1}Checking System Update Readiness.", "${t1}(p)`tCSI Payload Corrupt`t(n)`t`t`tamd64_microsoft-windows-foo_1\foo.dll", "${t1}Repair failed: Missing replacement payload.",
  "${t1}Operation: Detect and Repair ", "${t1}Total Detected Corruption:`t1", "${t1}Total Repaired Corruption:`t0", "${t1}Total Operation Time: 60 seconds.",
  "${t2}Checking System Update Readiness.", "${t2}(p)`tCSI Payload Corrupt`t(n)`t`t`tamd64_microsoft-windows-foo_1\foo.dll",
  "${t2}Operation: Detect only ", "${t2}Total Detected Corruption:`t1", "${t2}Total Repaired Corruption:`t0", "${t2}Total Operation Time: 30 seconds.") | Set-Content (Join-Path $fakeRoot 'Logs/CBS/CBS.log')
$oldRoot = $env:SystemRoot; $env:SystemRoot = $fakeRoot
function global:sfc.exe { $global:LASTEXITCODE = 0 }
$OutDir3 = $OutDir + '-deep'; Remove-Item $OutDir3 -Recurse -Force -ErrorAction SilentlyContinue
$deepSrc = $src.Replace('& "$env:SystemRoot\System32\sfc.exe" /verifyonly | Out-Null', '$global:LASTEXITCODE = 0').Replace("'Logs\CBS\CBS.log'", "'Logs/CBS/CBS.log'")
& ([scriptblock]::Create($deepSrc)) -NoSensors -Offline -NoOpen -DeepScan -OutDir $OutDir3 *> $null
$env:SystemRoot = $oldRoot
$r = Get-Content (Get-ChildItem $OutDir3 -Filter '*.json' | Select-Object -First 1).FullName -Raw | ConvertFrom-Json
Expect 'deep scan: store reported damaged' (Has 'windows' 'warn' 'component store is damaged')
Expect 'deep scan: repair log explains the repair could not fix it' (Has 'windows' 'warn' 'could not fix 1 of 1')
Expect 'deep scan: repair history table' (@(((Area 'windows').tables | Where-Object { $_.title -match '^Component store scans' }).rows).Count -eq 2)

# 7. a FAILED event-log query must not produce an all-clear
function global:Get-WinEvent { param($FilterHashtable, $MaxEvents, $ErrorAction) Write-Error -Message 'Access is denied' -ErrorId 'System.UnauthorizedAccessException' -ErrorAction Stop }
$OutDir2 = $OutDir + '-denied'
Remove-Item $OutDir2 -Recurse -Force -ErrorAction SilentlyContinue
& $script -NoSensors -Offline -NoOpen -OutDir $OutDir2 *> $null
$r = Get-Content (Get-ChildItem $OutDir2 -Filter '*.json' | Select-Object -First 1).FullName -Raw | ConvertFrom-Json
Expect 'failed log query: no green "No system crashes"' (-not (Has 'crash' 'ok' 'No system crashes'))
Expect 'failed log query: reported as not verified' (Has 'crash' 'gap' 'Not verified: No system crashes')
Expect 'failed log query: listed in collection notes' ([bool](@($r.meta.errors | Where-Object { $_ -match 'Event log .* could not be read' }).Count))
Expect 'failed log query: crash area is not Healthy' ((Area 'crash').status -eq 'limited')

Write-Host $(if ($fail) { "$fail check(s) failed" } else { 'smoke test passed' })
exit $fail
