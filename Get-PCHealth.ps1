#Requires -Version 5.1
<#
.SYNOPSIS
    Passive Windows PC health check that produces an HTML dashboard.

.DESCRIPTION
    Reads health evidence that already exists on the machine: SMART / storage
    reliability counters, hardware error logs (WHEA), sensor readings, the
    driver inventory, Windows Update state and the servicing stack.

    It never runs a stress test, benchmark or surface scan, so it does not
    add wear to any component. The only optional heavier operation is
    -DeepScan, which runs the read-only DISM /ScanHealth and SFC /verifyonly.

.PARAMETER DeepScan
    Also run DISM ScanHealth and SFC /verifyonly (read-only, 10-20 minutes).

.PARAMETER NoSensors
    Do not download or load LibreHardwareMonitor (no kernel driver is loaded;
    temperatures, fans and voltages will be missing).

.PARAMETER Offline
    Make no network calls (no Windows Update search, no vendor lookups, no
    LibreHardwareMonitor download; an already downloaded copy is still used).

.PARAMETER Days
    How far back to look in the event logs. Default 30.

.PARAMETER OutDir
    Where to write the report. Default: .\reports next to this script.

.PARAMETER NoOpen
    Do not open the dashboard in the browser when finished.

.NOTES
    This file is deliberately pure ASCII so Windows PowerShell 5.1 parses it
    correctly regardless of the system code page.
#>
[CmdletBinding()]
param(
    [switch]$DeepScan,
    [switch]$NoSensors,
    [switch]$Offline,
    [int]$Days = 30,
    [string]$OutDir,
    [switch]$NoOpen
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$started = Get-Date
$Since = $started.AddDays(-1 * $Days)

# ---------------------------------------------------------------- elevation
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$IsAdmin = (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin -and $PSCommandPath) {
    Write-Host 'Requesting administrator rights (needed for SMART, sensors and driver store)...'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', ('"{0}"' -f $PSCommandPath))
    foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) { if ($v) { $argList += "-$k" } }
        else { $argList += "-$k"; $argList += ('"{0}"' -f $v) }
    }
    try {
        Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -ArgumentList $argList -ErrorAction Stop
        return
    } catch {
        Write-Warning 'Elevation was declined. Continuing with limited data.'
    }
}

try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

# ------------------------------------------------------------------ helpers
$script:Areas = [ordered]@{}
$script:Errors = New-Object System.Collections.ArrayList
$script:Sensors = New-Object System.Collections.ArrayList
$script:SensorNote = ''
$script:SensorSource = ''
$script:Links = New-Object System.Collections.ArrayList
$script:WuPending = @()
$script:WuSearched = $false

function New-Area([string]$id, [string]$name) {
    $script:Areas[$id] = [ordered]@{
        id = $id; name = $name; status = 'ok'; summary = ''
        gauges = (New-Object System.Collections.ArrayList)
        findings = (New-Object System.Collections.ArrayList)
        facts = (New-Object System.Collections.ArrayList)
        tables = (New-Object System.Collections.ArrayList)
    }
}
function Add-Fact([string]$area, [string]$k, $v) {
    if ($null -eq $v -or "$v" -eq '') { return }
    [void]$script:Areas[$area].facts.Add([ordered]@{ k = $k; v = [string]$v })
}
# sev: ok | info | warn | crit
function Add-Finding([string]$area, [string]$sev, [string]$title, [string]$detail, [string]$action, [string]$link) {
    [void]$script:Areas[$area].findings.Add([ordered]@{
        sev = $sev; title = $title; detail = $detail; action = $action; link = $link })
}
function Add-Gauge([string]$area, [string]$label, [double]$value, [string]$unit, [double]$max, [string]$sev, [string]$note) {
    [void]$script:Areas[$area].gauges.Add([ordered]@{
        label = $label; value = [math]::Round($value, 1); unit = $unit; max = $max; sev = $sev; note = $note })
}
function New-Cell([string]$text, [string]$sev, [string]$href) {
    return [ordered]@{ t = $text; s = $sev; href = $href }
}
function Add-Table([string]$area, [string]$title, [string[]]$cols, $rows, [string]$note, [bool]$collapsed) {
    if ($null -eq $rows -or $rows.Count -eq 0) { return }
    $colList = New-Object System.Collections.ArrayList
    foreach ($c in $cols) { [void]$colList.Add([string]$c) }
    [void]$script:Areas[$area].tables.Add([ordered]@{
        title = $title; cols = $colList; rows = $rows; note = $note; collapsed = $collapsed })
}
function New-Rows { return ,(New-Object System.Collections.ArrayList) }
function Format-Day($d) { if ($d) { try { return ([datetime]$d).ToString('yyyy-MM-dd') } catch { return '' } } return '' }
function Format-Stamp($d) { if ($d) { try { return ([datetime]$d).ToString('yyyy-MM-dd HH:mm') } catch { return '' } } return '' }
function Format-Size([double]$bytes) {
    if ($bytes -ge 1TB) { return ('{0:N2} TB' -f ($bytes / 1TB)) }
    if ($bytes -ge 1GB) { return ('{0:N0} GB' -f ($bytes / 1GB)) }
    return ('{0:N0} MB' -f ($bytes / 1MB))
}
function Get-Short([string]$s, [int]$n) {
    if (-not $s) { return '' }
    $s = ($s -replace '\s+', ' ').Trim()
    if ($s.Length -gt $n) { return $s.Substring(0, $n) + '...' }
    return $s
}
function Get-Ev([string]$log, [string]$provider, [int[]]$ids) {
    $f = @{ LogName = $log; StartTime = $Since }
    if ($provider) { $f.ProviderName = $provider }
    if ($ids) { $f.Id = $ids }
    try { return @(Get-WinEvent -FilterHashtable $f -MaxEvents 500 -ErrorAction Stop) } catch { return @() }
}
function Get-Cim([string]$class, [string]$ns, [string]$filter) {
    $p = @{ ClassName = $class; ErrorAction = 'Stop' }
    if ($ns) { $p.Namespace = $ns }
    if ($filter) { $p.Filter = $filter }
    try { return @(Get-CimInstance @p) } catch { return @() }
}
function Get-Web([string]$url) {
    $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36'
    return (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 20 -UserAgent $ua -ErrorAction Stop).Content
}
function Invoke-Step([string]$name, [scriptblock]$body) {
    Write-Host ('  - {0}' -f $name)
    try { & $body } catch {
        [void]$script:Errors.Add(('{0}: {1}' -f $name, $_.Exception.Message))
        Write-Host ('      (problem: {0})' -f $_.Exception.Message) -ForegroundColor DarkYellow
    }
}
function Get-Sens([string]$hwTypePattern, [string]$type) {
    return @($script:Sensors | Where-Object { $_.HwType -match $hwTypePattern -and $_.Type -eq $type })
}
function Get-TempSev([double]$v, [double]$warn, [double]$crit) {
    if ($v -ge $crit) { return 'crit' }
    if ($v -ge $warn) { return 'warn' }
    return 'ok'
}

New-Area 'cpu' 'CPU'
New-Area 'gpu' 'GPU'
New-Area 'memory' 'Memory'
New-Area 'drives' 'Drives'
New-Area 'psu' 'Power supply'
New-Area 'board' 'Motherboard'
New-Area 'windows' 'Windows'
New-Area 'drivers' 'Drivers'

Write-Host ''
Write-Host 'PC Health Check - passive read-only scan' -ForegroundColor Cyan
Write-Host ('Looking back {0} days in the event logs.' -f $Days)
Write-Host ''

# ------------------------------------------------- sensors (LibreHardwareMonitor)
function Get-LhmLibrary {
    $dir = Join-Path $PSScriptRoot 'lib\LibreHardwareMonitor'
    $dll = $null
    if (Test-Path $dir) {
        $dll = Get-ChildItem $dir -Filter 'LibreHardwareMonitorLib.dll' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if ($dll) { return $dll }
    if ($Offline) { $script:SensorNote = 'Offline mode and no local copy of LibreHardwareMonitor.'; return $null }

    Write-Host '      downloading LibreHardwareMonitor from GitHub (first run only)...'
    $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/LibreHardwareMonitor/LibreHardwareMonitor/releases/latest' `
        -Headers @{ 'User-Agent' = 'pc-health-check' } -TimeoutSec 30 -ErrorAction Stop
    $zips = @($rel.assets | Where-Object { $_.name -match '\.zip$' })
    $asset = $null
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $asset = $zips | Where-Object { $_.name -notmatch 'net4' } | Select-Object -First 1
    } else {
        $asset = $zips | Where-Object { $_.name -match 'net4' } | Select-Object -First 1
        if (-not $asset) { $asset = $zips | Where-Object { $_.name -match '^LibreHardwareMonitor\.zip$' } | Select-Object -First 1 }
    }
    if (-not $asset) { $asset = $zips | Select-Object -First 1 }
    if (-not $asset) { throw 'No downloadable LibreHardwareMonitor package found.' }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $zip = Join-Path $dir $asset.name
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
    Expand-Archive -Path $zip -DestinationPath $dir -Force
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Set-Content -Path (Join-Path $dir 'VERSION.txt') -Value ('{0} ({1})' -f $rel.tag_name, $asset.name)
    return (Get-ChildItem $dir -Filter 'LibreHardwareMonitorLib.dll' -Recurse | Select-Object -First 1)
}

function Read-LhmHardware($hw) {
    $hw.Update()
    foreach ($s in $hw.Sensors) {
        if ($null -ne $s.Value) {
            [void]$script:Sensors.Add([pscustomobject]@{
                Hw = [string]$hw.Name; HwType = [string]$hw.HardwareType
                Name = [string]$s.Name; Type = [string]$s.SensorType; Value = [double]$s.Value })
        }
    }
    foreach ($sub in $hw.SubHardware) { Read-LhmHardware $sub }
}

if (-not $NoSensors) {
    Invoke-Step 'Sensors (LibreHardwareMonitor)' {
        if (-not $IsAdmin) { $script:SensorNote = 'Not elevated, sensors skipped.'; return }
        $dll = Get-LhmLibrary
        if (-not $dll) { return }
        $script:LhmDir = $dll.DirectoryName
        Get-ChildItem $script:LhmDir -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
        $resolver = [ResolveEventHandler] {
            param($sender, $e)
            $n = (New-Object Reflection.AssemblyName $e.Name).Name
            $p = Join-Path $script:LhmDir ($n + '.dll')
            if (Test-Path $p) { return [Reflection.Assembly]::LoadFrom($p) }
            return $null
        }
        [AppDomain]::CurrentDomain.add_AssemblyResolve($resolver)
        $computer = $null
        try {
            [void][Reflection.Assembly]::LoadFrom($dll.FullName)
            $computer = New-Object LibreHardwareMonitor.Hardware.Computer
            foreach ($p in 'IsCpuEnabled', 'IsGpuEnabled', 'IsMotherboardEnabled', 'IsMemoryEnabled', 'IsStorageEnabled', 'IsPsuEnabled') {
                try { $computer.$p = $true } catch {}
            }
            $computer.Open()
            # Two reads a second apart: some sensors only report on the second poll.
            foreach ($hw in $computer.Hardware) { try { $hw.Update() } catch {} }
            Start-Sleep -Milliseconds 1200
            foreach ($hw in $computer.Hardware) { try { Read-LhmHardware $hw } catch {} }
            $script:SensorSource = 'LibreHardwareMonitor ' + $dll.VersionInfo.FileVersion
        } finally {
            if ($computer) { try { $computer.Close() } catch {} }   # unloads the kernel driver
            [AppDomain]::CurrentDomain.remove_AssemblyResolve($resolver)
        }
        if ($script:Sensors.Count -eq 0) { $script:SensorNote = 'LibreHardwareMonitor loaded but returned no readings.' }
    }
    if (-not $script:SensorSource -and -not $script:SensorNote) {
        $script:SensorNote = 'LibreHardwareMonitor could not be loaded (see collection notes).'
    }
} else {
    $script:SensorNote = 'Sensors disabled with -NoSensors.'
}

# ---------------------------------------------------------------------- CPU
$script:Whea = @()
Invoke-Step 'CPU' {
    $cpus = Get-Cim 'Win32_Processor'
    $cpu = $cpus | Select-Object -First 1
    if ($cpu) {
        Add-Fact 'cpu' 'Model' $cpu.Name.Trim()
        Add-Fact 'cpu' 'Cores / threads' ('{0} / {1}' -f $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors)
        Add-Fact 'cpu' 'Socket' $cpu.SocketDesignation
        Add-Fact 'cpu' 'Rated speed' ('{0} MHz' -f $cpu.MaxClockSpeed)
        Add-Fact 'cpu' 'Load during scan' ('{0} %' -f $cpu.LoadPercentage)
    }
    $mcRev = $null
    try {
        $b = (Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -ErrorAction Stop).'Update Revision'
        if ($b -and $b.Length -ge 8) {
            $hi = [BitConverter]::ToUInt32($b, 4); $lo = [BitConverter]::ToUInt32($b, 0)
            if ($hi -ne 0) { $mcRev = $hi } else { $mcRev = $lo }
            Add-Fact 'cpu' 'Microcode revision' ('0x{0:X}' -f $mcRev)
        }
    } catch {}

    if ($cpu -and $cpu.Name -match 'i[579]-1[34]\d{3}(K|KF|KS|F|T)?(\s|$)' -and $null -ne $mcRev) {
        if ($mcRev -lt 0x12B) {
            Add-Finding 'cpu' 'warn' 'Microcode predates the Intel 13th/14th gen stability fix' `
                ('This desktop Core CPU family was affected by the "Vmin shift" instability issue, where elevated voltage requests cause permanent degradation. Microcode 0x12B or later contains the mitigations; this system reports 0x{0:X}.' -f $mcRev) `
                'Update the motherboard BIOS to a version that includes microcode 0x12B or newer.' ''
        } else {
            Add-Finding 'cpu' 'ok' 'Microcode includes the Intel 13th/14th gen voltage mitigations' ('Revision 0x{0:X} is 0x12B or newer.' -f $mcRev) '' ''
        }
    }

    $temps = Get-Sens '^Cpu$' 'Temperature'
    if ($temps.Count -gt 0) {
        $pkg = $temps | Where-Object { $_.Name -match 'Package|Tctl|Tdie|Core Max|CPU$' } | Sort-Object Value -Descending | Select-Object -First 1
        if (-not $pkg) { $pkg = $temps | Sort-Object Value -Descending | Select-Object -First 1 }
        $sev = Get-TempSev $pkg.Value 85 95
        Add-Gauge 'cpu' ('Temperature ({0})' -f $pkg.Name) $pkg.Value 'C' 110 $sev 'Snapshot at current load, not a stress test'
        if ($sev -ne 'ok') {
            Add-Finding 'cpu' $sev ('CPU is at {0:N0} C without a stress load' -f $pkg.Value) `
                ('Load during the scan was about {0} %. A temperature this high near idle points at cooling, not the silicon.' -f $cpu.LoadPercentage) `
                'Check the cooler is seated, the pump or fan is spinning, and the thermal paste is not dried out.' ''
        }
    }
    $load = Get-Sens '^Cpu$' 'Load' | Where-Object { $_.Name -match 'Total' } | Select-Object -First 1
    if ($load) { Add-Gauge 'cpu' 'Load' $load.Value '%' 100 'ok' '' }

    $script:Whea = Get-Ev 'System' 'Microsoft-Windows-WHEA-Logger' $null
    $fatal = @($script:Whea | Where-Object { $_.Id -in 18, 20 })
    $corrected = @($script:Whea | Where-Object { $_.Id -eq 19 })
    if ($fatal.Count -gt 0) {
        Add-Finding 'cpu' 'crit' ('{0} fatal machine-check error(s) logged' -f $fatal.Count) `
            ('Windows recorded uncorrectable hardware errors (WHEA event 18/20), most recently {0}. These come from the CPU reporting an internal, cache or bus fault.' -f (Format-Stamp $fatal[0].TimeCreated)) `
            'Remove any overclock or undervolt, load BIOS defaults, update the BIOS. If they continue at stock settings the CPU, motherboard or PSU is suspect.' ''
    }
    if ($corrected.Count -gt 0) {
        $sev = 'warn'; if ($corrected.Count -lt 3) { $sev = 'info' }
        Add-Finding 'cpu' $sev ('{0} corrected machine-check error(s) logged' -f $corrected.Count) `
            'The CPU detected and corrected internal errors (WHEA event 19). Occasional ones can be benign; a steady stream usually means an unstable overclock, undervolt or memory profile.' `
            'If you run PBO, Curve Optimizer, an undervolt or XMP/EXPO, back it off and see whether the count stops rising.' ''
    }
    $throttle = Get-Ev 'System' 'Microsoft-Windows-Kernel-Processor-Power' @(37)
    if ($throttle.Count -gt 0) {
        Add-Finding 'cpu' 'info' ('Firmware limited CPU speed {0} time(s)' -f $throttle.Count) `
            'Kernel-Processor-Power event 37: the firmware capped processor speed. This is usually thermal or power-limit throttling, and is routine on laptops.' `
            'On a desktop, check cooling and BIOS power limits.' ''
    }
    if ($fatal.Count -eq 0 -and $corrected.Count -eq 0) {
        Add-Finding 'cpu' 'ok' 'No CPU hardware errors logged' ('No machine-check events in the last {0} days.' -f $Days) '' ''
    }
}

# ---------------------------------------------------------------------- GPU
$script:Gpus = @()
Invoke-Step 'GPU' {
    $script:Gpus = @(Get-Cim 'Win32_VideoController' | Where-Object { $_.PNPDeviceID -match '^PCI' })
    $rows = New-Rows
    foreach ($g in $script:Gpus) {
        $st = 'ok'; if ($g.ConfigManagerErrorCode -ne 0) { $st = 'crit' }
        [void]$rows.Add(@([string]$g.Name, [string]$g.DriverVersion, (Format-Day $g.DriverDate),
                [string]$g.VideoModeDescription, (New-Cell ([string]$g.Status) $st '')))
        if ($g.ConfigManagerErrorCode -ne 0) {
            Add-Finding 'gpu' 'crit' ('{0} reports device error code {1}' -f $g.Name, $g.ConfigManagerErrorCode) `
                'Windows Device Manager is reporting a problem with this adapter. Code 43 means the driver stopped the device because it reported a fault.' `
                'Clean-install the vendor driver. If code 43 persists after that, reseat the card and its power cables; the card itself may be failing.' ''
        }
    }
    Add-Table 'gpu' 'Adapters' @('Adapter', 'Driver version', 'Driver date', 'Mode', 'Status') $rows '' $false

    $gt = Get-Sens '^Gpu' 'Temperature'
    foreach ($hwName in @($gt | Select-Object -ExpandProperty Hw -Unique)) {
        $t = $gt | Where-Object { $_.Hw -eq $hwName } | Sort-Object Value -Descending | Select-Object -First 1
        $sev = Get-TempSev $t.Value 88 100
        Add-Gauge 'gpu' ('{0} - {1}' -f $hwName, $t.Name) $t.Value 'C' 110 $sev 'Snapshot at current load'
        if ($sev -ne 'ok') {
            Add-Finding 'gpu' $sev ('{0} is at {1:N0} C' -f $hwName, $t.Value) 'That is high for a system that is not under a deliberate load.' `
                'Check the fans spin, clear dust from the heatsink, and check case airflow.' ''
        }
    }
    foreach ($f in (Get-Sens '^Gpu' 'Fan')) { Add-Fact 'gpu' ('{0} {1}' -f $f.Hw, $f.Name) ('{0:N0} RPM' -f $f.Value) }

    $tdr = Get-Ev 'System' 'Display' @(4101)
    $drvErr = @()
    foreach ($p in 'nvlddmkm', 'amdkmdag', 'amdwddmg', 'igfx') { $drvErr += @(Get-Ev 'System' $p $null | Where-Object { $_.Level -le 2 }) }
    if ($tdr.Count -gt 0) {
        $sev = 'warn'; if ($tdr.Count -ge 10) { $sev = 'crit' }
        Add-Finding 'gpu' $sev ('Display driver stopped responding and recovered {0} time(s)' -f $tdr.Count) `
            ('Event 4101 (TDR), most recently {0}. Causes in rough order of likelihood: a driver bug, an unstable GPU overclock or undervolt, overheating, insufficient PSU power, failing GPU.' -f (Format-Stamp $tdr[0].TimeCreated)) `
            'Note whether it follows one game or everything. Clean-install the current driver, remove any GPU tuning, then look at temperatures and power cabling.' ''
    }
    if ($drvErr.Count -gt 0) {
        Add-Finding 'gpu' 'warn' ('{0} error event(s) from the graphics kernel driver' -f $drvErr.Count) `
            ('Most recent: {0} - {1}' -f (Format-Stamp $drvErr[0].TimeCreated), (Get-Short $drvErr[0].Message 220)) '' ''
    }
    $lkr = @()
    if (Test-Path "$env:SystemRoot\LiveKernelReports") {
        $lkr = @(Get-ChildItem "$env:SystemRoot\LiveKernelReports" -Recurse -Filter '*.dmp' -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -ge $Since -and $_.FullName -match 'WATCHDOG' })
    }
    if ($lkr.Count -gt 0) {
        Add-Finding 'gpu' 'warn' ('{0} GPU watchdog dump(s) written' -f $lkr.Count) `
            'Windows wrote live kernel reports in the WATCHDOG folder, which it does when the GPU hangs (LiveKernelEvent 141 / 117).' '' ''
    }
    if ($tdr.Count -eq 0 -and $drvErr.Count -eq 0 -and $lkr.Count -eq 0) {
        Add-Finding 'gpu' 'ok' 'No display driver crashes or GPU hangs logged' ('Nothing in the last {0} days.' -f $Days) '' ''
    }
}

# ------------------------------------------------------------------- memory
Invoke-Step 'Memory' {
    $dimms = Get-Cim 'Win32_PhysicalMemory'
    $rows = New-Rows
    $slow = $false
    foreach ($d in $dimms) {
        $cfg = $d.ConfiguredClockSpeed
        if ($d.Speed -and $cfg -and $cfg -lt $d.Speed) { $slow = $true }
        [void]$rows.Add(@([string]$d.DeviceLocator, (Format-Size $d.Capacity), ([string]$d.Manufacturer).Trim(),
                ([string]$d.PartNumber).Trim(), ('{0} MHz' -f $d.Speed), ('{0} MHz' -f $cfg)))
    }
    Add-Table 'memory' 'Modules' @('Slot', 'Size', 'Maker', 'Part number', 'Rated', 'Running at') $rows '' $false
    $os = Get-Cim 'Win32_OperatingSystem' | Select-Object -First 1
    if ($os) {
        $total = $os.TotalVisibleMemorySize * 1KB; $free = $os.FreePhysicalMemory * 1KB
        $usedPct = 100 * ($total - $free) / $total
        Add-Gauge 'memory' ('In use of {0}' -f (Format-Size $total)) $usedPct '%' 100 'ok' ''
    }
    if ($slow) {
        Add-Finding 'memory' 'info' 'Memory is running below its rated speed' `
            'At least one module reports a higher rated speed than it is configured for. That normally means XMP / EXPO is not enabled in the BIOS. This is a performance point, not a health fault.' `
            'Enable the XMP or EXPO profile in the BIOS if you want the rated speed.' ''
    }
    $memWhea = @($script:Whea | Where-Object { $_.Message -match 'memory' -or $_.Id -in 46, 47 })
    if ($memWhea.Count -gt 0) {
        Add-Finding 'memory' 'warn' ('{0} hardware memory error event(s) logged' -f $memWhea.Count) `
            'WHEA recorded memory errors. On consumer (non-ECC) systems this is uncommon and worth acting on.' `
            'Run Windows Memory Diagnostic or MemTest86 once, with XMP/EXPO disabled, to separate bad memory from an unstable profile.' ''
    }
    $diag = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-MemoryDiagnostics-Results' } -MaxEvents 1 -ErrorAction SilentlyContinue
    if ($diag) {
        Add-Fact 'memory' 'Last Windows Memory Diagnostic' ('{0}: {1}' -f (Format-Day $diag.TimeCreated), (Get-Short $diag.Message 160))
    } else {
        Add-Fact 'memory' 'Last Windows Memory Diagnostic' 'No result on record'
    }
    if ($memWhea.Count -eq 0) {
        Add-Finding 'memory' 'ok' 'No memory hardware errors logged' 'This is passive evidence only. Memory can only be proven good by a memory test, which this tool deliberately does not run.' '' ''
    }
}

# ------------------------------------------------------------------- drives
Invoke-Step 'Drives' {
    $rows = New-Rows
    $disks = @()
    try { $disks = @(Get-PhysicalDisk -ErrorAction Stop) } catch {}
    foreach ($d in $disks) {
        $r = $null
        try { $r = $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch {}
        $hs = [string]$d.HealthStatus
        $hsSev = 'ok'
        if ($hs -eq 'Warning') { $hsSev = 'warn' } elseif ($hs -ne 'Healthy') { $hsSev = 'crit' }
        $name = [string]$d.FriendlyName
        if ($hsSev -ne 'ok') {
            Add-Finding 'drives' $hsSev ('{0} reports health status "{1}"' -f $name, $hs) `
                ('Operational status: {0}. The drive itself is signalling a problem.' -f ($d.OperationalStatus -join ', ')) `
                'Back up anything on this drive now, then plan its replacement.' ''
        }
        $wear = ''; $temp = ''; $hours = ''; $errs = ''
        if ($r) {
            if ($null -ne $r.Wear) {
                $wear = ('{0} %' -f $r.Wear)
                $ws = 'ok'; if ($r.Wear -ge 90) { $ws = 'crit' } elseif ($r.Wear -ge 70) { $ws = 'warn' }
                if ($d.MediaType -ne 'HDD') {
                    Add-Gauge 'drives' ('{0} - rated life used' -f $name) $r.Wear '%' 100 $ws 'Percentage of rated write endurance consumed'
                    if ($ws -ne 'ok') {
                        Add-Finding 'drives' $ws ('{0} has used {1} % of its rated write endurance' -f $name, $r.Wear) `
                            'SSDs often outlive this figure, but past 100 % the manufacturer no longer guarantees data retention.' 'Plan a replacement and keep backups current.' ''
                    }
                }
            }
            if ($r.Temperature) {
                $temp = ('{0} C' -f $r.Temperature)
                $limit = 70; if ($d.MediaType -eq 'HDD') { $limit = 55 }
                if ($r.Temperature -ge $limit) {
                    Add-Finding 'drives' 'warn' ('{0} is at {1} C' -f $name, $r.Temperature) 'That is warm for a drive that is not being stressed.' 'Check airflow over the drive; M.2 drives under a GPU often benefit from a heatsink.' ''
                }
            }
            if ($r.PowerOnHours) { $hours = ('{0:N0} h' -f $r.PowerOnHours) }
            $u = [double]$r.ReadErrorsUncorrected + [double]$r.WriteErrorsUncorrected
            $errs = [string]$u
            if ($u -gt 0) {
                Add-Finding 'drives' 'warn' ('{0} has {1} uncorrected read/write error(s)' -f $name, $u) `
                    'The drive failed to recover data on at least one operation over its lifetime.' 'Check the cable (SATA), back up, and watch whether the number rises between runs.' ''
            }
        }
        [void]$rows.Add(@($name, [string]$d.MediaType, [string]$d.BusType, (Format-Size $d.Size), (New-Cell $hs $hsSev ''),
                $wear, $temp, $hours, $errs, [string]$d.FirmwareVersion))
    }
    Add-Table 'drives' 'Physical drives' @('Drive', 'Type', 'Bus', 'Size', 'Health', 'Life used', 'Temp', 'Power-on', 'Uncorrected errors', 'Firmware') $rows `
        'Read from the drive''s own SMART / NVMe health log. No surface scan or write test is performed.' $false
    if ($disks.Count -eq 0) { Add-Finding 'drives' 'info' 'Could not enumerate physical drives' 'Get-PhysicalDisk returned nothing; run elevated.' '' '' }

    foreach ($p in (Get-Cim 'MSStorageDriver_FailurePredictStatus' 'root\wmi')) {
        if ($p.PredictFailure) {
            Add-Finding 'drives' 'crit' 'A drive is predicting its own failure (SMART)' ('Instance: {0}' -f $p.InstanceName) 'Back up immediately and replace the drive.' ''
        }
    }
    foreach ($s in ($script:Sensors | Where-Object { $_.HwType -eq 'Storage' -and $_.Name -match 'Available Spare$|Remaining Life' })) {
        if ($s.Value -lt 20) {
            Add-Finding 'drives' 'warn' ('{0}: {1} is down to {2:N0} %' -f $s.Hw, $s.Name, $s.Value) '' 'Plan a replacement and keep backups current.' ''
        }
    }

    $vrows = New-Rows
    try {
        foreach ($v in @(Get-Volume -ErrorAction Stop | Where-Object { $_.DriveLetter -and $_.Size -gt 0 -and $_.DriveType -eq 'Fixed' } | Sort-Object DriveLetter)) {
            $freePct = 100 * $v.SizeRemaining / $v.Size
            $sev = 'ok'; if ($freePct -lt 5) { $sev = 'crit' } elseif ($freePct -lt 10) { $sev = 'warn' }
            Add-Gauge 'drives' ('{0}: space used' -f $v.DriveLetter) (100 - $freePct) '%' 100 $sev ('{0} free of {1}' -f (Format-Size $v.SizeRemaining), (Format-Size $v.Size))
            if ($sev -ne 'ok') {
                Add-Finding 'drives' $sev ('Volume {0}: has only {1:N0} % free' -f $v.DriveLetter, $freePct) 'Low free space slows SSDs (less room for wear levelling) and can block Windows updates.' 'Free up space or move data.' ''
            }
            $vh = 'ok'; if ([string]$v.HealthStatus -ne 'Healthy') { $vh = 'warn' }
            [void]$vrows.Add(@(('{0}:' -f $v.DriveLetter), [string]$v.FileSystemLabel, [string]$v.FileSystem, (Format-Size $v.Size),
                    (Format-Size $v.SizeRemaining), (New-Cell ([string]$v.HealthStatus) $vh '')))
            if ($vh -ne 'ok') { Add-Finding 'drives' 'warn' ('File system on {0}: is flagged {1}' -f $v.DriveLetter, $v.HealthStatus) '' ('Run: chkdsk {0}: /scan' -f $v.DriveLetter) '' }
        }
    } catch {}
    Add-Table 'drives' 'Volumes' @('Volume', 'Label', 'File system', 'Size', 'Free', 'Health') $vrows '' $false

    $bad = @(Get-Ev 'System' 'disk' @(7, 52))
    $io = @(Get-Ev 'System' 'disk' @(11, 51, 153)) + @(Get-Ev 'System' 'stornvme' @(11)) + @(Get-Ev 'System' 'Ntfs' @(55))
    if ($bad.Count -gt 0) {
        Add-Finding 'drives' 'crit' ('{0} bad-block / failure-prediction event(s)' -f $bad.Count) (Get-Short $bad[0].Message 220) 'Back up now and identify which drive the event names.' ''
    }
    if ($io.Count -gt 0) {
        Add-Finding 'drives' 'warn' ('{0} disk I/O or file-system error event(s)' -f $io.Count) `
            ('Most recent {0}: {1}' -f (Format-Stamp $io[0].TimeCreated), (Get-Short $io[0].Message 200)) `
            'Often a cable, port or external USB drive rather than the disk. If it names an internal drive, reseat or replace the cable first.' ''
    }
    if ($bad.Count -eq 0 -and $io.Count -eq 0) { Add-Finding 'drives' 'ok' 'No disk error events logged' ('Nothing in the last {0} days.' -f $Days) '' '' }
}

# ---------------------------------------------------------------------- PSU
Invoke-Step 'Power supply' {
    Add-Finding 'psu' 'info' 'PSU health is inferred, not measured' `
        'Most power supplies have no data connection to the PC. This verdict is built from the voltage rails as seen by the motherboard sensor chip and from Windows power-loss events. A PSU can be marginal under heavy load and still look clean here.' '' ''

    $volts = Get-Sens 'SuperIO|Motherboard|EmbeddedController' 'Voltage'
    $rows = New-Rows
    $judged = 0
    foreach ($v in $volts) {
        $nominal = 0
        if ($v.Name -match '12\s?V') { $nominal = 12 }
        elseif ($v.Name -match '(^|[^\d.])\+?5\s?V') { $nominal = 5 }
        elseif ($v.Name -match '3\.3\s?V|3VCC|3V3|AVCC|3VSB|AVSB') { $nominal = 3.3 }
        $cell = New-Cell '-' '' ''
        if ($nominal -gt 0) {
            $dev = 100 * ($v.Value - $nominal) / $nominal
            if ([math]::Abs($dev) -le 15) {
                $judged++
                $sev = 'ok'; if ([math]::Abs($dev) -gt 8) { $sev = 'crit' } elseif ([math]::Abs($dev) -gt 5) { $sev = 'warn' }
                $cell = New-Cell ('{0:+0.0;-0.0} % vs {1} V' -f $dev, $nominal) $sev ''
                if ($sev -ne 'ok') {
                    Add-Finding 'psu' $sev ('{0} rail reads {1:N2} V ({2:+0.0;-0.0} %)' -f $v.Name, $v.Value, $dev) `
                        'The ATX specification allows +/-5 %. Motherboard sensor readings are approximate, so treat this as a prompt to verify, not proof.' `
                        'Confirm in the BIOS hardware monitor or with a multimeter before replacing anything.' ''
                }
            } else {
                $cell = New-Cell 'not a scaled rail reading' '' ''
            }
        }
        if ($v.Name -match 'VBAT|CMOS|Battery' -and $v.Value -gt 0.5 -and $v.Value -lt 2.7) {
            Add-Finding 'board' 'warn' ('CMOS battery reads {0:N2} V' -f $v.Value) 'A CR2032 below about 2.7 V is near the end of its life; the symptom is the clock and BIOS settings resetting.' 'Replace the CR2032 coin cell.' ''
        }
        [void]$rows.Add(@([string]$v.Hw, [string]$v.Name, ('{0:N3} V' -f $v.Value), $cell))
    }
    Add-Table 'psu' 'Voltage readings' @('Source', 'Sensor', 'Reading', 'Against ATX nominal') $rows `
        'Sensor-chip labels are not standardised; only readings clearly labelled as a 12 V, 5 V or 3.3 V rail are judged.' $false
    if ($judged -eq 0) {
        $why = 'No labelled voltage rails were readable.'
        if ($script:SensorNote) { $why = $script:SensorNote }
        Add-Finding 'psu' 'info' 'No voltage rail readings available' $why 'The BIOS hardware monitor page shows the same rails if you want to check them by eye.' ''
    } elseif (@($script:Areas['psu'].findings | Where-Object { $_.sev -in 'warn', 'crit' }).Count -eq 0) {
        Add-Finding 'psu' 'ok' ('{0} voltage rail reading(s) within ATX tolerance' -f $judged) 'Measured at the current (light) load.' '' ''
    }

    $psuSens = @($script:Sensors | Where-Object { $_.HwType -eq 'Psu' })
    if ($psuSens.Count -gt 0) {
        $prow = New-Rows
        foreach ($s in $psuSens) { [void]$prow.Add(@([string]$s.Hw, [string]$s.Name, [string]$s.Type, ('{0:N2}' -f $s.Value))) }
        Add-Table 'psu' 'Digital PSU telemetry' @('PSU', 'Sensor', 'Type', 'Value') $prow '' $false
    }

    $kp = Get-Ev 'System' 'Microsoft-Windows-Kernel-Power' @(41)
    $noBugcheck = 0
    foreach ($e in $kp) { try { if ([int64]$e.Properties[0].Value -eq 0) { $noBugcheck++ } } catch {} }
    $dirty = Get-Ev 'System' 'EventLog' @(6008)
    Add-Fact 'psu' 'Unexpected shutdowns (event 6008)' $dirty.Count
    Add-Fact 'psu' 'Kernel-Power 41 events' $kp.Count
    if ($kp.Count -gt 0) {
        $sev = 'warn'; if ($noBugcheck -ge 5) { $sev = 'crit' }
        Add-Finding 'psu' $sev ('System lost power or reset without shutting down {0} time(s)' -f $kp.Count) `
            ('{0} of these had no bugcheck code, meaning Windows did not crash first: power simply went away or the machine was reset. Most recent: {1}. Holding the power button, a power cut or a hard freeze cause the same event.' -f $noBugcheck, (Format-Stamp $kp[0].TimeCreated)) `
            'If you did not cause these yourself and they happen under load (gaming, rendering), the PSU or its cabling is the first suspect, then GPU and motherboard.' ''
    } else {
        Add-Finding 'psu' 'ok' 'No unexpected power-loss events logged' ('Nothing in the last {0} days.' -f $Days) '' ''
    }

    foreach ($b in (Get-Cim 'Win32_Battery')) {
        $full = (Get-Cim 'BatteryFullChargedCapacity' 'root\wmi' | Select-Object -First 1).FullChargedCapacity
        $design = (Get-Cim 'BatteryStaticData' 'root\wmi' | Select-Object -First 1).DesignedCapacity
        if ($full -and $design) {
            $pct = 100 * $full / $design
            $sev = 'ok'; if ($pct -lt 50) { $sev = 'crit' } elseif ($pct -lt 70) { $sev = 'warn' }
            Add-Gauge 'psu' 'Battery capacity vs design' $pct '%' 100 $sev ''
            if ($sev -ne 'ok') { Add-Finding 'psu' $sev ('Battery holds {0:N0} % of its design capacity' -f $pct) '' 'Consider a replacement battery.' '' }
        }
    }
}

# -------------------------------------------------------------- motherboard
$script:Board = $null
Invoke-Step 'Motherboard' {
    $script:Board = Get-Cim 'Win32_BaseBoard' | Select-Object -First 1
    $bios = Get-Cim 'Win32_BIOS' | Select-Object -First 1
    $cs = Get-Cim 'Win32_ComputerSystem' | Select-Object -First 1
    if ($script:Board) {
        Add-Fact 'board' 'Board' ('{0} {1}' -f $script:Board.Manufacturer, $script:Board.Product)
        Add-Fact 'board' 'Revision' $script:Board.Version
    }
    if ($cs) { Add-Fact 'board' 'System' ('{0} {1}' -f $cs.Manufacturer, $cs.Model) }
    if ($bios) {
        Add-Fact 'board' 'BIOS version' $bios.SMBIOSBIOSVersion
        Add-Fact 'board' 'BIOS date' (Format-Day $bios.ReleaseDate)
        if ($bios.ReleaseDate) {
            $ageY = ($started - [datetime]$bios.ReleaseDate).TotalDays / 365
            if ($ageY -ge 2) {
                Add-Finding 'board' 'info' ('BIOS is {0:N1} years old' -f $ageY) `
                    'Old firmware is not a fault. Updates are worth taking when they carry CPU microcode, memory compatibility or security fixes.' `
                    'Check the board''s support page (linked in the Drivers section) and read the changelog before deciding.' ''
            }
        }
    }
    try { Add-Fact 'board' 'Secure Boot' ([string](Confirm-SecureBootUEFI -ErrorAction Stop)) } catch { Add-Fact 'board' 'Secure Boot' 'Not available (legacy boot or not elevated)' }
    try { $tpm = Get-Tpm -ErrorAction Stop; Add-Fact 'board' 'TPM' ('Present: {0}, ready: {1}' -f $tpm.TpmPresent, $tpm.TpmReady) } catch {}

    $bus = @($script:Whea | Where-Object { $_.Id -eq 17 })
    $other = @($script:Whea | Where-Object { $_.Id -notin 17, 18, 19, 20, 46, 47 -and $_.Level -le 3 })
    if ($bus.Count -gt 0) {
        $sev = 'warn'; if ($bus.Count -lt 5) { $sev = 'info' }
        Add-Finding 'board' $sev ('{0} corrected bus / PCIe error(s) logged' -f $bus.Count) `
            ('WHEA event 17: a device on the PCI Express bus had a corrected error. Most recent: {0}' -f (Get-Short $bus[0].Message 200)) `
            'Reseat the GPU and M.2 drives. Riser cables and PCIe power-saving (ASPM) are the usual causes.' ''
    }
    if ($other.Count -gt 0) {
        Add-Finding 'board' 'warn' ('{0} other hardware error event(s) logged' -f $other.Count) (Get-Short $other[0].Message 220) '' ''
    }
    if ($script:Whea.Count -eq 0) { Add-Finding 'board' 'ok' 'No hardware error (WHEA) events logged' ('Nothing in the last {0} days.' -f $Days) '' '' }

    foreach ($t in (Get-Sens 'SuperIO|Motherboard|EmbeddedController' 'Temperature' | Where-Object { $_.Value -gt 5 -and $_.Value -lt 120 } | Sort-Object Value -Descending | Select-Object -First 3)) {
        Add-Gauge 'board' ('{0}' -f $t.Name) $t.Value 'C' 110 (Get-TempSev $t.Value 80 95) $t.Hw
    }
    $srows = New-Rows
    foreach ($s in ($script:Sensors | Sort-Object HwType, Hw, Type, Name)) {
        [void]$srows.Add(@([string]$s.HwType, [string]$s.Hw, [string]$s.Type, [string]$s.Name, ('{0:N2}' -f $s.Value)))
    }
    Add-Table 'board' 'All sensor readings' @('Kind', 'Hardware', 'Type', 'Sensor', 'Value') $srows ('Source: {0}' -f $script:SensorSource) $true

    if ($script:Sensors.Count -gt 0 -and (Get-Sens 'SuperIO' 'Voltage').Count -eq 0 -and (Get-Sens '^Cpu$' 'Temperature').Count -eq 0) {
        Add-Finding 'board' 'info' 'CPU and motherboard sensors were not readable' `
            'LibreHardwareMonitor returned data for some devices but not the CPU or the board sensor chip. Recent LibreHardwareMonitor releases need the separate PawnIO driver for low-level access, and some anti-cheat or core-isolation settings block it.' `
            'Install PawnIO from pawnio.eu and re-run if you want temperatures and voltage rails.' 'https://pawnio.eu/'
    } elseif ($script:Sensors.Count -eq 0 -and $script:SensorNote) {
        Add-Finding 'board' 'info' 'No sensor data in this report' $script:SensorNote '' ''
    }
}

# ------------------------------------------------------------------ Windows
Invoke-Step 'Windows installation' {
    $os = Get-Cim 'Win32_OperatingSystem' | Select-Object -First 1
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    if ($os) {
        Add-Fact 'windows' 'Edition' $os.Caption
        Add-Fact 'windows' 'Version' ('{0} (build {1}.{2})' -f $cv.DisplayVersion, $os.BuildNumber, $cv.UBR)
        Add-Fact 'windows' 'Installed' (Format-Day $os.InstallDate)
        Add-Fact 'windows' 'Last boot' (Format-Stamp $os.LastBootUpTime)
        $up = ($started - $os.LastBootUpTime).TotalDays
        if ($up -ge 14) {
            Add-Finding 'windows' 'info' ('Windows has been up for {0:N0} days' -f $up) 'With Fast Startup enabled, "Shut down" does not reset the kernel, so uptime keeps counting.' 'Use Restart occasionally so updates and driver changes fully apply.' ''
        }
        if ([int]$os.BuildNumber -lt 22000) {
            Add-Finding 'windows' 'warn' 'Windows 10 is past end of support' 'Windows 10 stopped receiving free security updates on 14 October 2025 unless the PC is enrolled in Extended Security Updates.' 'Enrol in ESU or move to Windows 11.' ''
        }
    }
    $pending = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $pending += 'component servicing' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $pending += 'Windows Update' }
    if ($pending.Count -gt 0) {
        Add-Finding 'windows' 'warn' 'A restart is pending' ('Waiting on: {0}. Until then, updates are half-applied.' -f ($pending -join ', ')) 'Restart the PC.' ''
    }

    if ($IsAdmin) {
        try {
            $img = Repair-WindowsImage -Online -CheckHealth -ErrorAction Stop
            $state = [string]$img.ImageHealthState
            Add-Fact 'windows' 'Component store flag' $state
            if ($state -ne 'Healthy') {
                $sev = 'warn'; if ($state -eq 'NonRepairable') { $sev = 'crit' }
                Add-Finding 'windows' $sev ('Component store is flagged {0}' -f $state) 'Windows has previously detected corruption in its own servicing store.' 'Run: DISM /Online /Cleanup-Image /RestoreHealth   then: sfc /scannow' ''
            }
        } catch { [void]$script:Errors.Add('DISM CheckHealth: ' + $_.Exception.Message) }
    }
    if ($DeepScan -and $IsAdmin) {
        Write-Host '      deep scan: DISM ScanHealth (several minutes)...'
        try {
            $scan = Repair-WindowsImage -Online -ScanHealth -ErrorAction Stop
            $state = [string]$scan.ImageHealthState
            $sev = 'ok'; if ($state -eq 'Repairable') { $sev = 'warn' } elseif ($state -ne 'Healthy') { $sev = 'crit' }
            Add-Finding 'windows' $sev ('DISM ScanHealth result: {0}' -f $state) 'Full read-only scan of the component store.' $(if ($sev -ne 'ok') { 'Run: DISM /Online /Cleanup-Image /RestoreHealth' } else { '' }) ''
        } catch { Add-Finding 'windows' 'info' 'DISM ScanHealth could not complete' $_.Exception.Message '' '' }
        Write-Host '      deep scan: SFC /verifyonly (several minutes)...'
        & "$env:SystemRoot\System32\sfc.exe" /verifyonly | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Add-Finding 'windows' 'ok' 'SFC found no integrity violations' 'System File Checker verified protected system files (read-only).' '' ''
        } else {
            Add-Finding 'windows' 'warn' ('SFC reported problems or could not finish (exit code {0})' -f $LASTEXITCODE) 'Details are in C:\Windows\Logs\CBS\CBS.log (lines tagged [SR]).' 'Run: sfc /scannow' ''
        }
    } else {
        Add-Finding 'windows' 'info' 'System file integrity was not deep-scanned' 'This run only read the existing corruption flag, which is fast but only reflects problems Windows has already noticed.' 'Re-run with -DeepScan (Run-PCHealth-DeepScan.cmd) for a full read-only DISM and SFC verification.' ''
    }

    $bc = Get-Ev 'System' 'Microsoft-Windows-WER-SystemErrorReporting' @(1001)
    if ($bc.Count -gt 0) {
        $sev = 'warn'; if ($bc.Count -ge 3) { $sev = 'crit' }
        Add-Finding 'windows' $sev ('{0} blue-screen crash(es) in the last {1} days' -f $bc.Count, $Days) `
            'The bugcheck codes are in the table below. The same code repeating points at one cause; different codes each time point at memory, CPU stability or power.' `
            'Search the bugcheck code, or open the dumps in C:\Windows\Minidump with WinDbg (!analyze -v).' ''
        $brow = New-Rows
        foreach ($e in ($bc | Select-Object -First 15)) { [void]$brow.Add(@((Format-Stamp $e.TimeCreated), (Get-Short $e.Message 260))) }
        Add-Table 'windows' 'Blue-screen history' @('When', 'Bugcheck') $brow '' $false
    } else {
        Add-Finding 'windows' 'ok' 'No blue-screen crashes logged' ('Nothing in the last {0} days.' -f $Days) '' ''
    }

    try {
        $hf = @(Get-HotFix -ErrorAction Stop | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending)
        if ($hf.Count -gt 0) {
            Add-Fact 'windows' 'Last update installed' ('{0} ({1})' -f (Format-Day $hf[0].InstalledOn), $hf[0].HotFixID)
            $age = ($started - $hf[0].InstalledOn).TotalDays
            if ($age -gt 45) {
                Add-Finding 'windows' 'warn' ('No Windows update installed for {0:N0} days' -f $age) 'Security updates ship monthly.' 'Open Settings > Windows Update and check for updates.' ''
            }
        }
    } catch {}

    if (-not $Offline) {
        Write-Host '      querying Windows Update (can take a minute)...'
        try {
            $session = New-Object -ComObject Microsoft.Update.Session
            $searcher = $session.CreateUpdateSearcher()
            $res = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software' or IsInstalled=0 and IsHidden=0 and Type='Driver'")
            $script:WuSearched = $true
            $all = @(); foreach ($u in $res.Updates) { $all += $u }
            $script:WuPending = @($all | Where-Object { $_.Type -eq 2 })
            $sw = @($all | Where-Object { $_.Type -ne 2 })
            if ($sw.Count -gt 0) {
                Add-Finding 'windows' 'warn' ('{0} Windows update(s) waiting to install' -f $sw.Count) '' 'Open Settings > Windows Update.' ''
                $urow = New-Rows
                foreach ($u in $sw) { [void]$urow.Add(@((Get-Short ([string]$u.Title) 140), [string]$u.MsrcSeverity)) }
                Add-Table 'windows' 'Pending updates' @('Update', 'Severity') $urow '' $false
            } else {
                Add-Finding 'windows' 'ok' 'No Windows updates pending' '' '' ''
            }
            $n = $searcher.GetTotalHistoryCount()
            if ($n -gt 0) {
                $hist = @($searcher.QueryHistory(0, [math]::Min(300, $n)) | Where-Object { $_.Date -ge $Since })
                $failed = @($hist | Where-Object { $_.ResultCode -eq 4 })
                if ($failed.Count -gt 0) {
                    Add-Finding 'windows' 'warn' ('{0} update installation failure(s) in the last {1} days' -f $failed.Count, $Days) `
                        ('Most recent: {0}' -f (Get-Short ([string]$failed[0].Title) 160)) 'If the same update keeps failing, run the deep scan and then the Windows Update troubleshooter.' ''
                }
                $script:WuHistory = $hist
            }
        } catch { [void]$script:Errors.Add('Windows Update search: ' + $_.Exception.Message) }
    }

    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        Add-Fact 'windows' 'Defender real-time protection' ([string]$mp.RealTimeProtectionEnabled)
        Add-Fact 'windows' 'Defender signature age' ('{0} day(s)' -f $mp.AntivirusSignatureAge)
        if ($mp.AntivirusEnabled -and -not $mp.RealTimeProtectionEnabled) { Add-Finding 'windows' 'warn' 'Defender real-time protection is off' '' 'Turn it back on in Windows Security unless another antivirus is in charge.' '' }
        if ($mp.AntivirusEnabled -and $mp.AntivirusSignatureAge -gt 7) { Add-Finding 'windows' 'warn' ('Defender signatures are {0} days old' -f $mp.AntivirusSignatureAge) '' 'Check for updates in Windows Security.' '' }
    } catch {
        $av = @(Get-Cim 'AntiVirusProduct' 'root\SecurityCenter2' | ForEach-Object { $_.displayName })
        if ($av.Count -gt 0) { Add-Fact 'windows' 'Antivirus' ($av -join ', ') }
    }

    $svc = @(Get-Cim 'Win32_Service' "StartMode='Auto' AND State<>'Running'" | Where-Object { $_.ExitCode -ne 0 -and $_.ExitCode -ne 1077 })
    if ($svc.Count -gt 0) {
        $srow = New-Rows
        foreach ($s in $svc) { [void]$srow.Add(@([string]$s.DisplayName, [string]$s.Name, [string]$s.State, [string]$s.ExitCode)) }
        Add-Table 'windows' 'Automatic services that stopped with an error' @('Service', 'Name', 'State', 'Exit code') $srow '' $false
        Add-Finding 'windows' 'info' ('{0} automatic service(s) are stopped with an error code' -f $svc.Count) 'Listed below. Some of these are harmless leftovers from uninstalled software.' '' ''
    }
}

# ------------------------------------------------------------------ drivers
function Add-Link([string]$what, [string]$source, [string]$url, [string]$why) {
    [void]$script:Links.Add(@($what, (New-Cell $source '' $url), $why))
}
function ConvertTo-Ver([string]$s) { try { return [version]$s } catch { return $null } }

Invoke-Step 'Drivers' {
    $keyClasses = 'DISPLAY', 'NET', 'MEDIA', 'BLUETOOTH', 'SYSTEM', 'HDC', 'SCSIADAPTER', 'USB', 'MONITOR', 'HIDCLASS', 'MOUSE', 'KEYBOARD', 'CAMERA', 'AUDIOENDPOINT', 'SOFTWARECOMPONENT', 'EXTENSION', 'FIRMWARE', 'BIOMETRIC'
    $all = @(Get-Cim 'Win32_PnPSignedDriver' | Where-Object { $_.DriverVersion -and $_.DeviceName })
    $third = @($all | Where-Object { $_.DriverProviderName -and $_.DriverProviderName -notmatch '^Microsoft' })
    $seen = @{}
    $rows = New-Rows
    $old = 0; $unsigned = 0
    foreach ($d in ($third | Sort-Object DeviceClass, DeviceName)) {
        $key = '{0}|{1}' -f $d.DeviceName, $d.DriverVersion
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = 1
        $ageTxt = ''; $ageSev = ''
        if ($d.DriverDate) {
            $y = ($started - [datetime]$d.DriverDate).TotalDays / 365
            $ageTxt = ('{0:N1} y' -f $y)
            if ($d.DeviceClass -eq 'DISPLAY' -and $y -ge 1) { $ageSev = 'warn' }
            elseif ($y -ge 4) { $ageSev = 'info'; $old++ }
        }
        $sig = New-Cell 'Yes' '' ''
        if ($d.IsSigned -eq $false) { $sig = New-Cell 'No' 'warn' ''; $unsigned++ }
        [void]$rows.Add(@([string]$d.DeviceName, [string]$d.DeviceClass, [string]$d.DriverProviderName, [string]$d.DriverVersion,
                (Format-Day $d.DriverDate), (New-Cell $ageTxt $ageSev ''), $sig))
    }
    Add-Table 'drivers' ('Installed third-party drivers ({0})' -f $rows.Count) @('Device', 'Class', 'Provider', 'Version', 'Date', 'Age', 'Signed') $rows `
        'Microsoft in-box drivers are omitted; they are serviced by Windows Update. Age alone is not a fault: many chipset and device drivers are legitimately years old.' $true
    Add-Fact 'drivers' 'Drivers in use' ('{0} total, {1} third-party' -f $all.Count, $third.Count)
    if ($unsigned -gt 0) { Add-Finding 'drivers' 'warn' ('{0} unsigned driver(s) in use' -f $unsigned) 'See the Signed column in the driver table.' 'Replace with a signed version from the manufacturer.' '' }
    if ($old -gt 0) { Add-Finding 'drivers' 'info' ('{0} third-party driver(s) are more than four years old' -f $old) 'Usually fine. Worth a look only for network, audio, storage and chipset devices where the maker still publishes updates.' '' '' }

    # devices Windows itself says are broken
    $prob = @(Get-Cim 'Win32_PnPEntity' 'root\cimv2' 'ConfigManagerErrorCode<>0')
    $codeText = @{ 1 = 'not configured correctly'; 10 = 'cannot start'; 12 = 'not enough free resources'; 14 = 'needs a restart'; 18 = 'drivers need reinstalling'
        19 = 'registry configuration damaged'; 22 = 'disabled'; 24 = 'not present or not working'; 28 = 'no driver installed'; 31 = 'driver failed to load'
        32 = 'driver service disabled'; 37 = 'driver failed to initialise'; 39 = 'driver corrupt or missing'; 43 = 'device reported a fault'; 45 = 'not connected'; 52 = 'driver signature not verified' }
    $prow = New-Rows
    $real = 0
    foreach ($p in $prob) {
        $c = [int]$p.ConfigManagerErrorCode
        if ($c -eq 45) { continue }
        $sev = 'warn'; if ($c -eq 22) { $sev = 'info' } else { $real++ }
        $txt = $codeText[$c]; if (-not $txt) { $txt = 'see Device Manager' }
        [void]$prow.Add(@([string]$p.Name, [string]$p.PNPClass, (New-Cell ('Code {0}: {1}' -f $c, $txt) $sev ''), (Get-Short ([string]$p.PNPDeviceID) 60)))
    }
    Add-Table 'drivers' 'Devices with a problem' @('Device', 'Class', 'Problem', 'Device ID') $prow '' $false
    if ($real -gt 0) { Add-Finding 'drivers' 'warn' ('{0} device(s) are not working according to Device Manager' -f $real) 'Listed in the table below. Code 28 means no driver at all; that is typically a chipset or motherboard-utility device.' 'Install the missing driver from the motherboard or PC maker''s support page.' '' }
    else { Add-Finding 'drivers' 'ok' 'Device Manager reports no failed devices' '' '' '' }

    # ---- Windows versus vendor conflicts
    $basic = @($all | Where-Object { $_.DeviceClass -eq 'DISPLAY' -and $_.DeviceName -match 'Basic Display' })
    if ($basic.Count -gt 0) {
        Add-Finding 'drivers' 'warn' 'A graphics adapter is running on the Microsoft Basic Display driver' 'No vendor driver is bound to it, so there is no acceleration. This happens after a failed driver install or a driver removal.' 'Install the GPU vendor driver (links below).' ''
    }
    $generic = @($all | Where-Object {
            $_.DeviceClass -in 'DISPLAY', 'NET', 'MEDIA', 'BLUETOOTH' -and $_.DriverProviderName -match '^Microsoft' -and
            $_.Manufacturer -match 'NVIDIA|AMD|Advanced Micro|Intel|Realtek|Qualcomm|MediaTek|Broadcom|Killer|Creative|Marvell|Aquantia' -and
            $_.DeviceName -notmatch 'WAN Miniport|Virtual|Wi-Fi Direct|Kernel Debug|Enumerator|Basic Display|High Definition Audio Device' })
    if ($generic.Count -gt 0) {
        $grow = New-Rows
        foreach ($g in $generic) { [void]$grow.Add(@([string]$g.DeviceName, [string]$g.DeviceClass, [string]$g.Manufacturer, [string]$g.DriverVersion, (Format-Day $g.DriverDate))) }
        Add-Table 'drivers' 'Vendor hardware running on a Microsoft in-box driver' @('Device', 'Class', 'Hardware maker', 'Version', 'Date') $grow '' $false
        Add-Finding 'drivers' 'info' ('{0} vendor device(s) use a generic Microsoft driver' -f $generic.Count) 'These work, but the manufacturer''s own driver usually adds features or fixes. Not a conflict in itself.' 'Optional: install the maker''s driver from the links below.' ''
    }

    $wuBlocked = $false
    try { if ((Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -ErrorAction Stop).ExcludeWUDriversInQualityUpdate -eq 1) { $wuBlocked = $true } } catch {}
    try { if ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching' -ErrorAction Stop).SearchOrderConfig -eq 0) { $wuBlocked = $true } } catch {}
    Add-Fact 'drivers' 'Windows Update may install drivers' $(if ($wuBlocked) { 'No (blocked by policy or setting)' } else { 'Yes (default)' })

    $conflicts = 0
    $staged = @()
    if ($IsAdmin) { try { $staged = @(Get-WindowsDriver -Online -ErrorAction Stop) } catch { [void]$script:Errors.Add('Driver store: ' + $_.Exception.Message) } }
    if ($staged.Count -gt 0) {
        Add-Fact 'drivers' 'Third-party packages in driver store' $staged.Count
        $drow = New-Rows
        $groups = $staged | Group-Object { '{0}|{1}|{2}' -f $_.ClassName, $_.ProviderName, [IO.Path]::GetFileName($_.OriginalFileName) } | Where-Object { $_.Count -gt 1 }
        foreach ($g in $groups) {
            $vers = @($g.Group | Sort-Object { ConvertTo-Ver $_.Version } -Descending)
            $first = $vers[0]
            if ($first.ClassName -notin 'Display', 'Net', 'MEDIA', 'Media', 'System', 'Bluetooth', 'HDC', 'SCSIAdapter', 'USB') { continue }
            [void]$drow.Add(@([string]$first.ClassName, [string]$first.ProviderName, [IO.Path]::GetFileName($first.OriginalFileName),
                    (($vers | ForEach-Object { '{0} ({1})' -f $_.Version, (Format-Day $_.Date) }) -join ', ')))
        }
        Add-Table 'drivers' 'Driver packages staged in more than one version' @('Class', 'Provider', 'Package', 'Versions (newest first)') $drow `
            'Normal after updates: Windows keeps old versions for roll-back. It matters only if the active driver is not the newest one (flagged separately).' $true

        foreach ($gpu in $script:Gpus) {
            $active = ConvertTo-Ver $gpu.DriverVersion
            if (-not $active) { continue }
            $vendorWord = ($gpu.Name -split ' ')[0]
            $cand = @($staged | Where-Object { $_.ClassName -eq 'Display' -and $_.ProviderName -match [regex]::Escape($vendorWord) } | ForEach-Object { ConvertTo-Ver $_.Version } | Where-Object { $_ } | Sort-Object -Descending)
            if ($cand.Count -gt 0 -and $cand[0] -gt $active) {
                $conflicts++
                Add-Finding 'drivers' 'warn' ('{0}: a newer driver is staged than the one in use' -f $gpu.Name) `
                    ('Active {0}, newest in the driver store {1}. This pattern appears when Windows Update or a roll-back replaced a newer vendor driver with an older one, or when an install has not finished.' -f $active, $cand[0]) `
                    'Restart first. If it persists, clean-install the vendor driver, and consider stopping Windows Update from delivering drivers (see the note below).' ''
            }
        }
    }

    # WU offering a driver that is older than the vendor one already installed
    $wrow = New-Rows
    foreach ($u in $script:WuPending) {
        $verdict = New-Cell 'Offered' 'info' ''
        $uDate = $null; try { $uDate = [datetime]$u.DriverVerDate } catch {}
        $match = $all | Where-Object { $_.DeviceClass -eq [string]$u.DriverClass -and $_.DriverProviderName -notmatch '^Microsoft' -and $u.DriverModel -and $_.DeviceName -eq [string]$u.DriverModel } | Select-Object -First 1
        if ($match -and $uDate -and $match.DriverDate -and $uDate -lt [datetime]$match.DriverDate) {
            $conflicts++
            $verdict = New-Cell ('OLDER than installed ({0})' -f (Format-Day $match.DriverDate)) 'warn' ''
            Add-Finding 'drivers' 'warn' ('Windows Update is offering an older driver for {0}' -f $u.DriverModel) `
                ('Offered driver is dated {0}; the installed vendor driver is dated {1}. If installed, it would downgrade the vendor driver.' -f (Format-Day $uDate), (Format-Day $match.DriverDate)) `
                'Do not install it from Optional updates. Hide it with Microsoft''s "Show or hide updates" tool (wushowhide) if it keeps returning.' ''
        }
        [void]$wrow.Add(@((Get-Short ([string]$u.Title) 110), [string]$u.DriverClass, (Format-Day $uDate), $verdict))
    }
    Add-Table 'drivers' 'Driver updates offered by Windows Update' @('Update', 'Class', 'Driver date', 'Verdict') $wrow 'These appear under Settings > Windows Update > Advanced options > Optional updates.' $false
    if ($script:WuSearched -and $script:WuPending.Count -gt 0) {
        Add-Finding 'drivers' 'info' ('Windows Update is offering {0} driver update(s)' -f $script:WuPending.Count) 'See the table below. Prefer the device maker''s own package for GPU, chipset, audio and network.' '' ''
    }

    if ($script:WuHistory) {
        $hrow = New-Rows
        $drvHist = @($script:WuHistory | Where-Object { $_.Title -match 'NVIDIA|Advanced Micro Devices|AMD |Intel|Realtek|Qualcomm|MediaTek|Logitech|Corsair|ASUS|Micro-Star|Gigabyte|Broadcom|Synaptics|Samsung' -and $_.Title -notmatch 'KB\d{6,}|Defender|Security Intelligence' })
        foreach ($h in $drvHist) {
            $rc = New-Cell 'Installed' '' ''; if ($h.ResultCode -eq 4) { $rc = New-Cell 'Failed' 'warn' '' }
            [void]$hrow.Add(@((Format-Stamp $h.Date), (Get-Short ([string]$h.Title) 120), $rc))
        }
        Add-Table 'drivers' ('Drivers Windows Update installed in the last {0} days' -f $Days) @('When', 'Driver', 'Result') $hrow `
            'If a GPU or chipset entry here is dated after you installed the vendor package yourself, Windows Update overwrote it.' $false
    }
    if (-not $wuBlocked -and @($third | Where-Object { $_.DeviceClass -eq 'DISPLAY' }).Count -gt 0) {
        Add-Finding 'drivers' 'info' 'Windows Update is allowed to replace vendor drivers' `
            'This is the Windows default. It is the mechanism behind most "Windows versus manufacturer driver" conflicts, typically a GPU driver being swapped for an older one.' `
            'If you manage GPU and chipset drivers yourself: Group Policy > Windows Update > "Do not include drivers with Windows Updates", or System Properties > Hardware > Device Installation Settings > No.' ''
    }
    if ($conflicts -eq 0) {
        Add-Finding 'drivers' 'ok' 'No Windows-versus-vendor driver conflict detected' 'No downgrade offers, no newer staged display driver than the active one.' '' ''
    }

    # ---- live GPU driver check
    $osId = 135; try { if ([int](Get-Cim 'Win32_OperatingSystem')[0].BuildNumber -lt 22000) { $osId = 57 } } catch {}
    $lrow = New-Rows
    foreach ($gpu in $script:Gpus) {
        $name = [string]$gpu.Name
        $installed = [string]$gpu.DriverVersion; $latest = ''; $src = ''; $note = ''
        $ageDays = 0; if ($gpu.DriverDate) { $ageDays = ($started - [datetime]$gpu.DriverDate).TotalDays }
        try {
            if ($name -match 'NVIDIA') {
                $src = 'https://www.nvidia.com/en-us/drivers/'
                $digits = ($installed -replace '\.', '')
                if ($digits.Length -ge 5) { $t = $digits.Substring($digits.Length - 5); $installed = '{0}.{1}' -f $t.Substring(0, 3), $t.Substring(3) }
                if ($name -match 'GTX (9|10)\d\d|GTX 7\d\d|GT \d') { $note = 'Legacy card: on a security-update-only driver branch, so the current Game Ready version does not apply.' }
                elseif (-not $Offline) {
                    foreach ($pair in @(@(127, 995), @(120, 877), @(120, 929))) {
                        $u = 'https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php?func=DriverManualLookup&psid={0}&pfid={1}&osID={2}&languageCode=1033&beta=0&isWHQL=1&dltype=-1&dch=1&upCRD=0&sort1=0&numberOfResults=1' -f $pair[0], $pair[1], $osId
                        $j = Invoke-RestMethod -Uri $u -TimeoutSec 20 -ErrorAction Stop
                        if ($j.IDS -and $j.IDS.Count -gt 0) { $latest = [uri]::UnescapeDataString([string]$j.IDS[0].downloadInfo.Version); break }
                    }
                    $note = 'Latest Game Ready driver for current-generation desktop cards.'
                }
            } elseif ($name -match 'AMD|Radeon') {
                $src = 'https://www.amd.com/en/support/download/drivers.html'
                try {
                    $rk = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}' -ErrorAction Stop |
                        ForEach-Object { Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue } | Where-Object { $_.RadeonSoftwareVersion } | Select-Object -First 1
                    if ($rk) { $installed = [string]$rk.RadeonSoftwareVersion }
                } catch {}
                if (-not $Offline) {
                    $html = Get-Web $src
                    $m = [regex]::Matches($html, 'Adrenalin(?:\s+Edition)?\s+(\d{2}\.\d{1,2}\.\d{1,2})')
                    $best = $null
                    foreach ($x in $m) { $v = ConvertTo-Ver $x.Groups[1].Value; if ($v -and (-not $best -or $v -gt $best)) { $best = $v } }
                    if ($best) { $latest = [string]$best }
                    $note = 'Latest Adrenalin Edition release named on AMD''s download page.'
                }
            } elseif ($name -match 'Intel') {
                $src = 'https://www.intel.com/content/www/us/en/download/785597/intel-arc-iris-xe-graphics-windows.html'
                if (-not $Offline -and $name -match 'Arc|Iris|UHD') {
                    $html = Get-Web $src
                    $m = [regex]::Match($html, '\b(3\d\.0\.10\d\.\d{4})\b')
                    if ($m.Success) { $latest = $m.Groups[1].Value }
                    $note = 'Latest Arc / Iris Xe package. Older integrated graphics use a different, frozen package.'
                }
            }
        } catch { $note = 'Live lookup failed ({0}). Check the vendor page.' -f (Get-Short $_.Exception.Message 80) }

        $verdict = New-Cell 'Not checked' '' ''
        if ($latest) {
            $vi = ConvertTo-Ver $installed; $vl = ConvertTo-Ver $latest
            if ($vi -and $vl -and $vl -gt $vi) {
                $sev = 'info'; if ($ageDays -gt 180) { $sev = 'warn' }
                $verdict = New-Cell 'Newer available' $sev ''
                Add-Finding 'drivers' $sev ('{0}: driver {1} installed, {2} available' -f $name, $installed, $latest) `
                    ('Installed driver is dated {0}. Newest is not automatically best for a GPU: if the current one is stable in your games, updating is a choice rather than a fix.' -f (Format-Day $gpu.DriverDate)) `
                    'Download from the vendor (link in the table below).' $src
            } elseif ($vi -and $vl) {
                $verdict = New-Cell 'Up to date' 'ok' ''
                Add-Finding 'drivers' 'ok' ('{0}: graphics driver is current ({1})' -f $name, $installed) '' '' ''
            } else { $verdict = New-Cell 'Could not compare' '' '' }
        } elseif ($ageDays -gt 365) {
            $verdict = New-Cell 'Over a year old' 'warn' ''
            Add-Finding 'drivers' 'warn' ('{0}: graphics driver is over a year old ({1})' -f $name, (Format-Day $gpu.DriverDate)) $note 'Check the vendor page for a current driver.' $src
        }
        [void]$lrow.Add(@($name, $installed, (Format-Day $gpu.DriverDate), $(if ($latest) { $latest } else { '-' }), $verdict, (New-Cell 'Vendor download page' '' $src), $note))
        if ($src) { Add-Link ('Graphics: {0}' -f $name) 'Vendor download page' $src 'Always take GPU drivers from the GPU vendor.' }
    }
    Add-Table 'drivers' 'Graphics driver: installed versus latest' @('Adapter', 'Installed', 'Dated', 'Latest found', 'Verdict', 'Get it', 'Note') $lrow `
        'The live lookup uses the vendors'' public web pages, not an official API, so it can fail when they change their sites.' $false

    # ---- where to get everything else
    $cpuName = [string](Get-Cim 'Win32_Processor' | Select-Object -First 1).Name
    if ($cpuName -match 'AMD') { Add-Link 'Chipset (AMD)' 'AMD chipset drivers' 'https://www.amd.com/en/support/download/drivers.html' 'Choose Chipsets, then your socket and chipset. Includes the power plan and PCI drivers.' }
    elseif ($cpuName -match 'Intel') { Add-Link 'Chipset, Wi-Fi, Bluetooth, LAN (Intel)' 'Intel Driver & Support Assistant' 'https://www.intel.com/content/www/us/en/support/detect.html' 'Intel''s own scanner identifies and updates Intel components.' }
    $mfr = ''; $prod = ''
    if ($script:Board) { $mfr = [string]$script:Board.Manufacturer; $prod = [string]$script:Board.Product }
    $sysMfr = [string](Get-Cim 'Win32_ComputerSystem' | Select-Object -First 1).Manufacturer
    $vendorUrl = ''
    if ($sysMfr -match 'Dell') { $vendorUrl = 'https://www.dell.com/support/home' }
    elseif ($sysMfr -match 'HP|Hewlett') { $vendorUrl = 'https://support.hp.com/drivers' }
    elseif ($sysMfr -match 'Lenovo') { $vendorUrl = 'https://pcsupport.lenovo.com/' }
    elseif ($mfr -match 'ASUS') { $vendorUrl = 'https://www.asus.com/support/download-center/' }
    elseif ($mfr -match 'Micro-Star|MSI') { $vendorUrl = 'https://www.msi.com/support/download' }
    elseif ($mfr -match 'Gigabyte') { $vendorUrl = 'https://www.gigabyte.com/Support' }
    elseif ($mfr -match 'ASRock') { $vendorUrl = 'https://www.asrock.com/support/index.asp' }
    $why = 'BIOS, audio (Realtek), LAN, Wi-Fi and board utilities. Board makers ship versions validated for this exact board.'
    if ($vendorUrl) { Add-Link ('Motherboard / system: {0} {1}' -f $mfr, $prod) 'Manufacturer support site' $vendorUrl $why }
    if ($prod) {
        $q = [uri]::EscapeDataString(('{0} {1} support drivers BIOS' -f $mfr, $prod))
        Add-Link ('Motherboard / system: {0} {1}' -f $mfr, $prod) 'Search for the exact support page' ('https://duckduckgo.com/?q=' + $q) 'Opens a web search for this exact model.'
    }
    Add-Link 'Everything else' 'Windows Update > Optional updates' 'ms-settings:windowsupdate-optionalupdates' 'Safe fallback for devices whose maker publishes only through Microsoft.'
    Add-Table 'drivers' 'Where to get the latest drivers' @('Component', 'Source', 'Why this source') $script:Links `
        'Avoid third-party "driver updater" utilities; they are a common source of wrong or bundled drivers.' $false
}

# ----------------------------------------------------------------- assemble
$rank = @{ ok = 0; info = 0; warn = 1; crit = 2 }
$overall = 'ok'
$areaList = New-Object System.Collections.ArrayList
foreach ($a in $script:Areas.Values) {
    $worst = 'ok'; $w = 0; $c = 0; $i = 0
    foreach ($f in $a.findings) {
        if ($f.sev -eq 'warn') { $w++ } elseif ($f.sev -eq 'crit') { $c++ } elseif ($f.sev -eq 'info') { $i++ }
        if ($rank[$f.sev] -gt $rank[$worst]) { $worst = $f.sev }
    }
    $a.status = $worst
    if ($c -gt 0) { $a.summary = ('{0} critical, {1} warning' -f $c, $w) }
    elseif ($w -gt 0) { $a.summary = ('{0} warning(s)' -f $w) }
    elseif ($a.findings.Count -eq 0) { $a.status = 'unknown'; $a.summary = 'No data collected' }
    elseif ($i -gt 0) { $a.summary = ('No problems found, {0} note(s)' -f $i) }
    else { $a.summary = 'No problems found' }
    if ($rank.ContainsKey($a.status) -and $rank[$a.status] -gt $rank[$overall]) { $overall = $a.status }
    [void]$areaList.Add($a)
}

$errList = New-Object System.Collections.ArrayList
foreach ($e in $script:Errors) { [void]$errList.Add([string]$e) }
$report = [ordered]@{
    meta = [ordered]@{
        computer = [string]$env:COMPUTERNAME
        generated = $started.ToString('yyyy-MM-dd HH:mm')
        elevated = [bool]$IsAdmin
        days = $Days
        deepScan = [bool]$DeepScan
        offline = [bool]$Offline
        sensorSource = [string]$script:SensorSource
        sensorNote = [string]$script:SensorNote
        durationSec = [int]((Get-Date) - $started).TotalSeconds
        overall = $overall
        errors = $errList
    }
    areas = $areaList
}

if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'reports' }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$stamp = $started.ToString('yyyyMMdd-HHmmss')
$base = Join-Path $OutDir ('PCHealth-{0}-{1}' -f $env:COMPUTERNAME, $stamp)
$json = ConvertTo-Json -InputObject $report -Depth 12 -Compress
$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText("$base.json", $json, $utf8)

$templatePath = Join-Path $PSScriptRoot 'dashboard.template.html'
if (Test-Path $templatePath) {
    $template = [IO.File]::ReadAllText($templatePath, [Text.Encoding]::UTF8)
    $safe = $json.Replace('</', '<\/')
    $html = $template.Replace('/*__REPORT_DATA__*/null', $safe)
    [IO.File]::WriteAllText("$base.html", $html, $utf8)
    Write-Host ''
    Write-Host ('Overall: {0}' -f $overall.ToUpper()) -ForegroundColor $(if ($overall -eq 'crit') { 'Red' } elseif ($overall -eq 'warn') { 'Yellow' } else { 'Green' })
    Write-Host ('Dashboard: {0}.html' -f $base)
    if (-not $NoOpen) { Start-Process "$base.html" }
} else {
    Write-Warning ('dashboard.template.html not found next to the script. Raw data written to {0}.json' -f $base)
}
if ($script:Errors.Count -gt 0) { Write-Host ('{0} collection step(s) had problems; they are listed at the bottom of the dashboard.' -f $script:Errors.Count) -ForegroundColor DarkYellow }
