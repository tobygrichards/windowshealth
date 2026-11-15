# Smoke test: runs the whole of Get-PCHealth.ps1 against a simulated PC, on any OS with PowerShell 7.
#   pwsh -File tests/Smoke-Test.ps1
# Windows-only cmdlets are replaced with stand-ins that return a small fake machine, the elevation
# prompt is skipped and fake sensor readings are injected. It proves the collector runs from start to
# finish without a script error and produces a dashboard; it does not prove the real Windows queries
# return what is expected. Exit code 0 = pass.
param([string]$OutDir = (Join-Path ([IO.Path]::GetTempPath()) 'pchealth-smoke'))

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
function global:Get-CimInstance {
    param($ClassName, $Namespace, $Filter, $ErrorAction)
    switch ($ClassName) {
        'Win32_Processor' { [pscustomobject]@{ Name = 'AMD Ryzen 9 5950X 16-Core Processor'; NumberOfCores = 16; NumberOfLogicalProcessors = 32; SocketDesignation = 'AM4'; MaxClockSpeed = 3400; LoadPercentage = 7 } }
        'Win32_VideoController' { [pscustomobject]@{ Name = 'AMD Radeon RX 9070 XT'; PNPDeviceID = 'PCI\VEN_1002'; DriverVersion = '32.0.31044.16'; DriverDate = (Get-Date).AddDays(-30); VideoModeDescription = '2560 x 1440'; Status = 'OK'; ConfigManagerErrorCode = 0 } }
        'Win32_OperatingSystem' { [pscustomobject]@{ Caption = 'Microsoft Windows 11 Pro'; BuildNumber = '26200'; InstallDate = (Get-Date).AddDays(-28); LastBootUpTime = (Get-Date).AddHours(-5); TotalVisibleMemorySize = 33554432; FreePhysicalMemory = 16777216 } }
        'Win32_BaseBoard' { [pscustomobject]@{ Manufacturer = 'ASUSTeK COMPUTER INC.'; Product = 'ROG STRIX X570-E GAMING WIFI II'; Version = 'Rev X.0x' } }
        'Win32_BIOS' { [pscustomobject]@{ SMBIOSBIOSVersion = '5044'; ReleaseDate = (Get-Date).AddMonths(-10) } }
        'Win32_ComputerSystem' { [pscustomobject]@{ Manufacturer = 'System manufacturer'; Model = 'System Product Name' } }
        'Win32_PhysicalMemory' { [pscustomobject]@{ DeviceLocator = 'DIMM_A2'; Capacity = 17179869184; Manufacturer = 'G.Skill'; PartNumber = 'F4-3600C16'; Speed = 3600; ConfiguredClockSpeed = 2133 } }
        'Win32_PnPSignedDriver' {
            [pscustomobject]@{ DeviceName = 'AMD Radeon RX 9070 XT'; DeviceClass = 'DISPLAY'; DriverProviderName = 'Advanced Micro Devices, Inc.'; Manufacturer = 'Advanced Micro Devices, Inc.'; DriverVersion = '32.0.31044.16'; DriverDate = (Get-Date).AddDays(-30); IsSigned = $true }
            [pscustomobject]@{ DeviceName = 'Realtek Audio'; DeviceClass = 'MEDIA'; DriverProviderName = 'Realtek'; Manufacturer = 'Realtek'; DriverVersion = '6.0.9000.1'; DriverDate = (Get-Date).AddYears(-5); IsSigned = $true }
        }
        'Win32_WmiClassThatFails' { throw 'simulated failure' }
        default { if ($ErrorAction -eq 'Stop' -and $ClassName -match 'Battery|FailurePredict|AntiVirus') { throw 'Invalid class' } }
    }
}
function global:Get-WinEvent { param($FilterHashtable, $MaxEvents, $ErrorAction) Write-Error -Message 'No events were found' -ErrorId 'NoMatchingEventsFound' -ErrorAction Stop }
function global:Get-PhysicalDisk {
    [pscustomobject]@{ FriendlyName = 'Samsung SSD 990 PRO 1TB'; DeviceId = '0'; MediaType = 'SSD'; BusType = 'NVMe'; Size = 1TB; HealthStatus = 'Healthy'; OperationalStatus = 'OK'; FirmwareVersion = '4B2QJXD7' }
    [pscustomobject]@{ FriendlyName = 'Samsung SSD 990 PRO 1TB'; DeviceId = '2'; MediaType = 'SSD'; BusType = 'NVMe'; Size = 1TB; HealthStatus = 'Healthy'; OperationalStatus = 'OK'; FirmwareVersion = '4B2QJXD7' }
    [pscustomobject]@{ FriendlyName = 'ST2000DM008-2FR102'; DeviceId = '1'; MediaType = 'HDD'; BusType = 'SATA'; Size = 2TB; HealthStatus = 'Healthy'; OperationalStatus = 'OK'; FirmwareVersion = '0001' }
}
function global:Get-StorageReliabilityCounter { param([Parameter(ValueFromPipeline)]$d, $ErrorAction) process { [pscustomobject]@{ Wear = 0; Temperature = 34; PowerOnHours = 900; ReadErrorsUncorrected = 0; WriteErrorsUncorrected = 0 } } }
function global:Get-Volume { [pscustomobject]@{ DriveLetter = 'C'; Size = 600GB; SizeRemaining = 277GB; DriveType = 'Fixed'; FileSystemLabel = ''; FileSystem = 'NTFS'; HealthStatus = 'Healthy' } }
foreach ($n in 'Confirm-SecureBootUEFI', 'Get-Tpm', 'Get-HotFix', 'Get-MpComputerStatus', 'Get-WindowsDriver', 'Repair-WindowsImage', 'Get-AppxPackage', 'Get-Service') {
    Set-Item -Path "function:global:$n" -Value { throw 'not available in the simulation' }
}

# 4. run it
Remove-Item $OutDir -Recurse -Force -ErrorAction SilentlyContinue
$script = [scriptblock]::Create($src)
$runErrors = @()
try { & $script -NoSensors -Offline -NoOpen -OutDir $OutDir -ErrorVariable +runErrors *> (Join-Path ([IO.Path]::GetTempPath()) 'pchealth-smoke.log') }
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
Expect 'nine areas reported' (@($r.areas).Count -eq 9)
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
Expect 'no crashes reported as ok when log query succeeded' (Has 'crash' 'ok' 'No system crashes')
Expect 'chipset package missing flagged' (Has 'drivers' 'warn' 'chipset driver package is not installed')
Expect 'overall is critical' ($r.meta.overall -eq 'crit')

# 5. a FAILED event-log query must not produce an all-clear
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
