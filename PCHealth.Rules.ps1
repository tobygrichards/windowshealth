# PCHealth.Rules.ps1
# Assessment rules for the PC health check. Every function here is pure: no WMI, registry, event log,
# network or file access. They take plain values in and return plain values, so they can be tested on
# any machine with tests\Run-Tests.ps1. Get-PCHealth.ps1 collects the data and calls these to judge it.
# This is the single place where limits and thresholds are defined.
# Pure ASCII, compatible with Windows PowerShell 5.1.

# Sensor names that are a device's published limit or offset rather than a measurement.
$script:RefSensor = 'Warning|Critical|Threshold|Limit|Resolution|Distance|TjMax|Offset'
$script:CpuTjMax = 95
$script:NoLimit = -1e9

function ConvertTo-Ver([string]$s) { try { return [version]$s } catch { return $null } }

# Highest version captured by group 1 of $pattern, returned exactly as the source wrote it (8.09, not 8.9).
function Get-MaxVer([string]$text, [string]$pattern) {
    $best = $null; $bestText = ''
    foreach ($m in [regex]::Matches($text, $pattern, 'IgnoreCase')) {
        $v = ConvertTo-Ver $m.Groups[1].Value
        if ($v -and (-not $best -or $v -gt $best)) { $best = $v; $bestText = $m.Groups[1].Value }
    }
    return $bestText
}

# "AMD Radeon(TM) RX 6800 XT" -> "amd-radeon-rx-6800-xt", the form AMD uses in its download page addresses.
function Get-AmdSlug([string]$name) {
    $s = $name.ToLower() -replace '\((tm|r)\)', ' ' -replace '\s+\d+-core processor.*$', '' -replace '\s+with radeon.*$', '' -replace '\s+series$', ''
    return (($s -replace '[^a-z0-9]+', '-').Trim('-'))
}

# Chipset token from a motherboard product name: "ROG STRIX X570-E GAMING" -> "x570", "B650M-A" -> "b650".
function Get-AmdChipsetToken([string]$boardProduct) {
    if ($boardProduct -match '(?<![A-Za-z0-9])([ABXabx]\d{3}[Ee]?)') { return $Matches[1].ToLower() }
    return ''
}

# The temperature at which a processor family throttles itself.
function Get-CpuTjMax([string]$cpuName) {
    if ($cpuName -match 'X3D') { return 89 }
    if ($cpuName -match 'Ryzen \d+ 5\d{3}') { return 90 }
    if ($cpuName -match 'Intel') { return 100 }
    return 95
}

# Nominal voltage of a supply rail, from the sensor's name. 0 when the name is not a rail.
function Get-RailNominal([string]$n) {
    if ($n -match '12\s?V') { return 12 }
    if ($n -match '(^|[^\d.])\+?5\s?V') { return 5 }
    if ($n -match '3\.3\s?V|3VCC|3V3|AVCC|3VSB|AVSB') { return 3.3 }
    return 0
}

# @(warning, critical) temperature for one drive: the limits the drive itself publishes when it does,
# otherwise general guidance. $driveId is the sensor library's identifier, e.g. /nvme/0 or /hdd/2.
function Get-DriveTempLimits($sensors, [string]$driveId) {
    $w = 70; $c = 80
    if ($driveId -match '/hdd/') { $w = 55; $c = 65 }
    $own = @($sensors | Where-Object { $_.HwType -eq 'Storage' -and $_.Type -eq 'Temperature' -and $_.Id -eq $driveId })
    $ow = $own | Where-Object { $_.Name -match 'Warning' -and $_.Value -gt 40 } | Select-Object -First 1
    $oc = $own | Where-Object { $_.Name -match 'Critical' -and $_.Value -gt 40 } | Select-Object -First 1
    if ($ow) { $w = $ow.Value }
    if ($oc) { $c = $oc.Value } elseif ($ow) { $c = $ow.Value + 5 }
    return @($w, $c)
}

# The range a sensor is EXPECTED to sit in for this kind of component.
# Returns @(low, high, criticalLow, criticalHigh, explanation, raiseFindingInMotherboardSection), or nothing
# when the sensor has no meaningful range (clock speeds, loads) or cannot be identified.
function Get-SensorSpec($s, $sensors) {
    $n = $s.Name; $none = $script:NoLimit
    if ($s.Type -eq 'Temperature') {
        if ($n -match $script:RefSensor) { return }
        if ($s.HwType -eq 'Cpu') { return @(10, ($script:CpuTjMax - 5), $none, ($script:CpuTjMax + 3), '', $false) }
        if ($s.HwType -match '^Gpu') {
            if ($n -match 'Hot ?Spot') { return @(10, 100, $none, 110, 'The hot spot is the hottest point on the GPU die. A gap of more than about 25 C above the core temperature suggests dried thermal paste or poor cooler contact.', $true) }
            return @(10, 88, $none, 100, '', $false)
        }
        if ($s.HwType -eq 'Storage') { $lim = Get-DriveTempLimits $sensors $s.Id; return @(0, ($lim[0] - 5), $none, $lim[1], '', $false) }
        if ($s.HwType -eq 'Memory') { return @(10, 55, $none, 65, 'Hot memory produces errors, particularly with XMP / EXPO enabled.', $true) }
        if ($n -match 'VRM|MOS') { return @(10, 100, $none, 115, 'The VRM feeds the CPU. Overheating VRMs throttle the CPU and cause shutdowns under load; improve airflow around the CPU socket.', $true) }
        if ($n -match 'Chipset|PCH') { return @(10, 80, $none, 95, 'X570 boards have a chipset fan; check it spins and is not clogged.', $true) }
        if ($n -match '^(CPU|System|Motherboard|T_Sensor|Water)') { return @(10, 80, $none, 95, 'Board-level temperatures this high point at case airflow.', $true) }
        return
    }
    if ($s.Type -eq 'Voltage') {
        $nom = Get-RailNominal $n
        if ($nom -gt 0 -and $s.HwType -ne 'Cpu') {
            # More than 30 % out means the input is not scaled as a rail on this board (a 12 V input reading 1 V).
            # Anything nearer than that is judged, so a rail that has genuinely collapsed is never hidden.
            if ([math]::Abs(100 * ($s.Value - $nom) / $nom) -gt 30) { return }
            return @(($nom * 0.95), ($nom * 1.05), ($nom * 0.92), ($nom * 1.08), 'The ATX specification allows +/-5 % on this rail.', $false)
        }
        if ($n -match 'VBAT|CMOS') { return @(2.7, 3.4, $none, 1e9, 'A CR2032 below about 2.7 V is near the end of its life; the symptom is the clock and BIOS settings resetting. Replace the coin cell.', $true) }
        if ($n -match 'SoC') { return @(0.85, 1.25, $none, 1.35, 'On Ryzen, SoC voltage above about 1.25 V risks long-term degradation and is a known cause of memory instability. It is normally set by the XMP / EXPO profile or by hand in the BIOS.', $true) }
        if ($n -match 'DRAM|DIMM') { return @(1.05, 1.5, $none, 1.6, 'DDR4 XMP profiles run at 1.35-1.5 V and DDR5 at 1.25-1.45 V. More than that needs active cooling and shortens module life.', $true) }
        if ($n -match 'SVI2|Vcore|CPU Core$|^Core$') { return @(0.2, 1.5, $none, 1.55, 'AMD specifies 1.55 V as the absolute maximum core voltage. Brief peaks near 1.5 V at light load are normal for Ryzen; sustained readings above that usually come from a manual voltage or aggressive PBO setting.', $true) }
        return
    }
    if ($s.Type -eq 'Fan' -and $n -match 'CPU' -and $n -notmatch 'OPT|Pump') {
        return @(1, 1e9, $none, 1e9, 'Nothing is spinning on the CPU fan header. Expected if an AIO pump or fan hub is connected elsewhere; otherwise the CPU cooler fan has stopped.', $true)
    }
    return
}

function Get-SensorUnit([string]$type) {
    switch ($type) {
        'Temperature' { return ' C' }
        'Voltage' { return ' V' }
        'Fan' { return ' RPM' }
        'Clock' { return ' MHz' }
        'Power' { return ' W' }
        'Load' { return ' %' }
        'Level' { return ' %' }
        'Control' { return ' %' }
        'Data' { return ' GB' }
        'SmallData' { return ' MB' }
        'Current' { return ' A' }
        'Throughput' { return ' B/s' }
        'Frequency' { return ' Hz' }
    }
    return ''
}

# Judges one sensor against its expected range, using the lowest and highest values seen.
# Returns @(severity, assessment text, finding detail or '', expected-range text).
# severity: 'ok' | 'warn' | 'crit' | 'info' (invalid reading) | '' (not judged)
function Get-SensorVerdict($s, $sensors) {
    if (-not $s.Valid) { $t = 'Invalid reading, ignored'; if ($s.Note) { $t = $s.Note }; return @('info', $t, '', '') }
    $sp = @(Get-SensorSpec $s $sensors)
    if ($sp.Count -eq 0) {
        $why = ''
        if ($s.Type -eq 'Temperature' -and $s.Name -match $script:RefSensor) { $why = 'Reference value, not a reading' }
        elseif ($s.Type -eq 'Temperature' -and $s.Name -match '^Temperature( #\d+)?$') { $why = 'Not judged: unlabelled input on the sensor chip' }
        elseif ($s.Type -eq 'Voltage' -and (Get-RailNominal $s.Name) -gt 0 -and $s.HwType -ne 'Cpu') { $why = 'Not judged: not a correctly scaled rail reading' }
        elseif ($s.Type -in 'Temperature', 'Voltage') { $why = 'Not judged: no known range for this sensor' }
        return @('', $why, '', '')
    }
    $u = Get-SensorUnit $s.Type
    if ($sp[1] -ge 1e9) { $range = ('above {0:0.##}{1}' -f ($sp[0] - 1), $u) } else { $range = ('{0:0.##} to {1:0.##}{2}' -f $sp[0], $sp[1], $u) }
    $detail = ''; if ($sp[5]) { $detail = $sp[4] }
    $sev = ''; $txt = ''
    if ($s.Max -ge $sp[3]) { $sev = 'crit'; $txt = ('{0:0.##}{1} is beyond the safe limit of {2:0.##}{1}' -f $s.Max, $u, $sp[3]) }
    elseif ($s.Min -le $sp[2]) { $sev = 'crit'; $txt = ('{0:0.##}{1} is below the safe limit of {2:0.##}{1}' -f $s.Min, $u, $sp[2]) }
    elseif ($s.Max -gt $sp[1]) { $sev = 'warn'; $txt = ('{0:0.##}{1} is above the expected range' -f $s.Max, $u) }
    elseif ($s.Min -lt $sp[0]) { $sev = 'warn'; $txt = ('{0:0.##}{1} is below the expected range' -f $s.Min, $u) }
    if (-not $sev) { return @('ok', 'Within expected range', '', $range) }
    if ($s.HwType -eq 'SuperIO') {
        # The board's sensor chip is a single unconfirmed source: report it as something to verify, never as critical.
        $sev = 'warn'; $txt += '. Low-confidence source (board sensor chip): confirm in the BIOS before acting'
    }
    return @($sev, $txt, $detail, $range)
}

# A reading that moved further between two samples a second apart than physics allows.
# Returns the reason, or '' when the sensor is plausible. Only supply rails are checked for voltage:
# CPU core voltage legitimately swings by far more than 10 % from one second to the next.
function Test-SensorErratic($s) {
    if ($s.Type -eq 'Temperature' -and $s.Step -gt 20) {
        return ('Erratic: jumped {0:N0} C between samples a few seconds apart, which is not physically possible' -f $s.Step)
    }
    if ($s.Type -eq 'Voltage' -and $s.HwType -eq 'SuperIO' -and (Get-RailNominal $s.Name) -gt 0 -and $s.Max -gt 0.5 -and ($s.Step / $s.Max) -gt 0.10) {
        return 'Erratic: jumped more than 10 % between samples a few seconds apart'
    }
    return ''
}

# The sensor library's readings that belong to ONE physical drive. Two drives of the same model share a
# name, so when a name matches several drives the one whose identifier ends in the Windows disk number is
# used; if that cannot be decided, nothing is returned rather than another drive's figures.
function Select-DriveSensors($sensors, [string]$name, $diskNumber) {
    $cand = @($sensors | Where-Object { $_.HwType -eq 'Storage' -and $_.Valid -and $name -and ($_.Hw -eq $name -or $_.Hw.Contains($name) -or $name.Contains($_.Hw)) })
    $ids = @($cand | ForEach-Object { $_.Id } | Select-Object -Unique)
    if ($ids.Count -le 1) { return $cand }
    $want = $ids | Where-Object { ($_ -split '/')[-1] -eq [string]$diskNumber } | Select-Object -First 1
    if (-not $want) { return @() }
    return @($cand | Where-Object { $_.Id -eq $want })
}

# The record closest in time to $t (within the window) that has not already been claimed by another crash.
function Select-NearestRecord($records, [datetime]$t, [hashtable]$used, [double]$minutesBefore, [double]$minutesAfter) {
    return ($records |
        Where-Object { $null -ne $_ -and -not $used.ContainsKey($_.RecordId) -and $_.TimeCreated -ge $t.AddMinutes(-1 * $minutesBefore) -and $_.TimeCreated -le $t.AddMinutes($minutesAfter) } |
        Sort-Object { [math]::Abs(($_.TimeCreated - $t).TotalSeconds) } | Select-Object -First 1)
}

# bugcheck code = name, suspect area, plain-English meaning
$script:Bugchecks = @{
    0x124 = @('WHEA_UNCORRECTABLE_ERROR', 'Hardware', 'The CPU reported a fatal hardware error. Almost never software: an unstable overclock, undervolt or memory profile, overheating, or a failing CPU, PSU or motherboard.')
    0x101 = @('CLOCK_WATCHDOG_TIMEOUT', 'CPU', 'A CPU core stopped responding. Typical of an unstable overclock, undervolt or Curve Optimizer setting; occasionally a failing CPU.')
    0x116 = @('VIDEO_TDR_FAILURE', 'GPU', 'The graphics driver hung and could not be reset. Graphics driver, GPU overheating or instability, or insufficient power to the card.')
    0x117 = @('VIDEO_TDR_TIMEOUT_DETECTED', 'GPU', 'The graphics driver took too long to respond.')
    0x119 = @('VIDEO_SCHEDULER_INTERNAL_ERROR', 'GPU', 'The graphics scheduler hit a fatal error. Graphics driver or failing GPU.')
    0x10E = @('VIDEO_MEMORY_MANAGEMENT_INTERNAL', 'GPU', 'Graphics memory manager error. Graphics driver or GPU memory.')
    0x1A = @('MEMORY_MANAGEMENT', 'Memory', 'Windows found its memory bookkeeping corrupted. Faulty or unstable RAM (XMP/EXPO), less often a driver.')
    0x4E = @('PFN_LIST_CORRUPT', 'Memory', 'Memory page list corrupted. Faulty or unstable RAM, or a driver writing where it should not.')
    0x12B = @('FAULTY_HARDWARE_CORRUPTED_PAGE', 'Memory', 'A memory page changed when nothing should have touched it. Strongly suggests faulty RAM.')
    0x50 = @('PAGE_FAULT_IN_NONPAGED_AREA', 'Driver or memory', 'Something referenced memory that does not exist. A buggy driver or faulty RAM.')
    0x0A = @('IRQL_NOT_LESS_OR_EQUAL', 'Driver or memory', 'A driver touched memory at the wrong priority level. Buggy driver, or faulty RAM.')
    0xD1 = @('DRIVER_IRQL_NOT_LESS_OR_EQUAL', 'Driver', 'A driver touched invalid memory. The dump normally names the driver; network and storage drivers are common.')
    0x3B = @('SYSTEM_SERVICE_EXCEPTION', 'Driver', 'A system call crashed in kernel code. Usually a driver (graphics and antivirus are common).')
    0x7E = @('SYSTEM_THREAD_EXCEPTION_NOT_HANDLED', 'Driver', 'A driver thread crashed. The dump normally names the driver.')
    0x1E = @('KMODE_EXCEPTION_NOT_HANDLED', 'Driver or memory', 'Kernel code hit an error it did not handle. A driver, or faulty RAM.')
    0x9F = @('DRIVER_POWER_STATE_FAILURE', 'Driver', 'A driver did not complete a sleep, wake or shutdown transition. Usually network, USB or graphics drivers.')
    0x133 = @('DPC_WATCHDOG_VIOLATION', 'Driver or storage', 'A driver held the CPU too long. Storage controller or SSD firmware, or network and graphics drivers.')
    0x139 = @('KERNEL_SECURITY_CHECK_FAILURE', 'Driver or memory', 'Kernel data structure corruption detected. A driver bug or faulty RAM.')
    0xEF = @('CRITICAL_PROCESS_DIED', 'Windows or storage', 'A process Windows cannot run without died. Corrupt system files, or a failing system drive.')
    0x7A = @('KERNEL_DATA_INPAGE_ERROR', 'Storage', 'Windows could not read its own data back from disk. Failing drive, cable or storage controller.')
    0xF4 = @('CRITICAL_OBJECT_TERMINATION', 'Storage', 'A critical process ended, most often because the system drive stopped responding.')
    0x7B = @('INACCESSIBLE_BOOT_DEVICE', 'Storage', 'Windows lost access to the boot drive. Storage driver, controller mode change or failing drive.')
    0x154 = @('UNEXPECTED_STORE_EXCEPTION', 'Storage', 'The memory compression store failed, most often because the system drive stalled.')
    0xC2 = @('BAD_POOL_CALLER', 'Driver', 'A driver made an invalid memory pool request.')
    0x19 = @('BAD_POOL_HEADER', 'Driver or memory', 'Kernel memory pool corrupted. A driver, or faulty RAM.')
}

# Returns @(name, suspect area, meaning) for a bugcheck code. Windows reports some codes with 0x10000000
# added (0x1000007E is the same failure as 0x7E), so that flag is removed before the lookup.
function Resolve-Bugcheck([int64]$code) {
    $k = $code
    if ($k -ge 0x10000000 -and $k -lt 0x20000000) { $k = $k - 0x10000000 }
    $info = $null
    if ($k -ge 0 -and $k -le 0x7FFFFFFF) { $info = $script:Bugchecks[[int]$k] }
    if (-not $info) { return @('(not in built-in table)', 'Unknown', 'Search this bugcheck code on Microsoft Learn for its meaning.') }
    return $info
}

# Overall state of one dashboard area from its findings.
# 'gap' findings mean "this could not be checked". An area with gaps and no faults is 'limited',
# never 'ok': absence of evidence is not reported as health.
function Get-AreaStatus($findings) {
    $c = 0; $w = 0; $g = 0; $i = 0; $n = 0
    foreach ($f in $findings) {
        $n++
        switch ($f.sev) { 'crit' { $c++ } 'warn' { $w++ } 'gap' { $g++ } 'info' { $i++ } }
    }
    if ($c -gt 0) { return @('crit', ('{0} critical, {1} warning' -f $c, $w)) }
    if ($w -gt 0) { return @('warn', ('{0} warning(s)' -f $w)) }
    if ($n -eq 0) { return @('unknown', 'No data collected') }
    if ($g -gt 0) { return @('limited', ('No problems found, but {0} check(s) could not be made' -f $g)) }
    if ($i -gt 0) { return @('ok', ('No problems found, {0} note(s)' -f $i)) }
    return @('ok', 'No problems found')
}

# Worst status across all areas. 'limited' and 'unknown' do not outrank 'ok' here; the dashboard
# reports them separately.
function Get-OverallStatus($statuses) {
    if ($statuses -contains 'crit') { return 'crit' }
    if ($statuses -contains 'warn') { return 'warn' }
    return 'ok'
}

# ------------------------------------------------------------------------------------------------
# Who installed a driver, and does it conflict with what the manufacturer offers?

# Reads Windows' own driver-installation log (C:\Windows\INF\setupapi.dev.log) and returns, for each
# third-party driver package (oemNN.inf), who last published it into the driver store:
#   @{ 'oem12.inf' = @{ Origin = 'Windows Update' | 'Manufacturer installer'; When = '...'; By = 'setup.exe' } }
# Only lines that record a package being PUBLISHED count, so a package merely considered during a
# Windows Update pass is not mislabelled.
function Get-DriverOriginsFromSetupLog($lines) {
    $map = @{}
    $isWu = $false; $when = ''; $by = ''; $infs = @()
    foreach ($line in @($lines) + '>>>  [end]') {
        if ($line.StartsWith('>>>  [')) {
            foreach ($i in $infs) {
                $origin = 'Manufacturer installer'; if ($isWu) { $origin = 'Windows Update' }
                $map[$i] = @{ Origin = $origin; When = $when; By = $by }
            }
            $isWu = ($line -match '\(Windows Update\)'); $when = ''; $by = ''; $infs = @()
            continue
        }
        if ($line -match '^>>>  Section start (\d{4}/\d{2}/\d{2})') { $when = $Matches[1]; continue }
        if ($line -match '^\s+cmd:\s+(.+)$') {
            $cmd = $Matches[1].Trim()
            if ($cmd -match 'wuauserv|usocoreworker|wuauclt|musnotif') { $isWu = $true }
            if ($cmd -match '([^\\/"]+\.exe)') { $by = $Matches[1].ToLower() }
            continue
        }
        if ($line -match 'SoftwareDistribution\\Download') { $isWu = $true }
        if ($line -match 'Publish' -and $line -match '(oem\d+\.inf)') { $infs += $Matches[1].ToLower() }
    }
    return $map
}

# Returns @(description, kind). kind: windows-inbox | windows-update | manufacturer | unknown
# $wuTitles = titles of drivers Windows Update reports having installed (used when the log has no entry).
function Get-DriverOrigin([string]$infName, [string]$version, [hashtable]$logOrigins, $wuTitles) {
    if (-not $infName) { return @('Unknown', 'unknown') }
    if ($infName -notmatch '^oem\d+\.inf$') { return @('Windows (built in)', 'windows-inbox') }
    $lo = $null; if ($logOrigins) { $lo = $logOrigins[$infName.ToLower()] }
    if ($lo) {
        $when = ''; if ($lo.When) { $when = ' on ' + ($lo.When -replace '/', '-') }
        if ($lo.Origin -eq 'Windows Update') { return @(('Windows Update' + $when), 'windows-update') }
        $by = ''; if ($lo.By) { $by = ' (' + $lo.By + ')' }
        return @(('Manufacturer installer' + $by + $when), 'manufacturer')
    }
    if ($version -and @($wuTitles | Where-Object { $_ -and ([string]$_).Contains($version) }).Count -gt 0) { return @('Windows Update', 'windows-update') }
    return @('Unknown', 'unknown')
}

# Compares the installed version with the manufacturer's and says whether Windows is the reason it is older.
# Returns @(severity, verdict text, isConflict).
# $sameSeries: require the first version number to match before comparing (board drivers use unrelated
# numbering for different chips or Windows versions, e.g. Realtek 10.x and 1125.x).
function Get-ConflictVerdict([string]$kind, [string]$installed, [string]$vendor, [bool]$sameSeries) {
    if (-not $vendor) { return @('', 'No manufacturer version to compare against', $false) }
    $vi = ConvertTo-Ver $installed; $vl = ConvertTo-Ver $vendor
    if (-not $vi -or -not $vl) { return @('gap', 'Could not compare: version numbers are not in a comparable form', $false) }
    if ($sameSeries -and $vi.Major -ne $vl.Major) { return @('gap', 'Could not compare: the two versions use different numbering series', $false) }
    $windows = $kind -in 'windows-inbox', 'windows-update'
    if ($vl -gt $vi) {
        if ($windows) { return @('warn', 'CONFLICT: Windows installed an older driver than the manufacturer offers', $true) }
        if ($kind -eq 'manufacturer') { return @('warn', 'Out of date: installed from the manufacturer, but a newer one exists', $false) }
        return @('warn', 'Older than the manufacturer''s; could not tell who installed it', $false)
    }
    if ($windows) { return @('ok', 'No conflict: Windows installed it, and it is not older than the manufacturer''s', $false) }
    return @('ok', 'Up to date', $false)
}

# "ROG STRIX X570-E GAMING WIFI II" -> "ROG-STRIX-X570-E-GAMING-WIFI-II", the model key ASUS uses.
function Get-AsusModelSlug([string]$product) {
    return (($product.Trim() -replace '[^A-Za-z0-9]+', '-').Trim('-'))
}

# From a board maker's driver listing (objects with Category, Version, Title, Date) returns the newest
# entry per device: one object per category + chip vendor + chip model.
function Get-BoardDriverLatest($files) {
    # Pass 1: classify every entry.
    $entries = @()
    foreach ($f in $files) {
        $cat = ''
        if ($f.Category -match '^LAN') { $cat = 'LAN' }
        elseif ($f.Category -match 'Wireless|Wi-?Fi') { $cat = 'Wireless' }
        elseif ($f.Category -match 'Bluetooth') { $cat = 'Bluetooth' }
        elseif ($f.Category -match 'Audio') { $cat = 'Audio' }
        if (-not $cat) { continue }
        $vendor = ''
        foreach ($v in 'Realtek', 'Intel', 'MediaTek', 'Qualcomm', 'Marvell', 'Aquantia', 'Broadcom', 'Killer') { if ($f.Title -match $v) { $vendor = $v; break } }
        if (-not $vendor -or -not (ConvertTo-Ver $f.Version)) { continue }
        $chip = ''
        $words = $f.Title -replace '[vV]?\d+(\.\d+)+', ' '      # drop version numbers so 6.0.9700.1 is not read as a chip
        if ($words -cmatch '\b(?:RTL)?(\d{4})[A-Z]{0,3}\b') { $chip = $Matches[1] }
        elseif ($words -cmatch '\b(I\d{3})\b') { $chip = $Matches[1] }
        $entries += [pscustomobject]@{ Category = $cat; Vendor = $vendor; Chip = $chip; Version = [string]$f.Version; Title = [string]$f.Title; Date = [string]$f.Date; Sole = $true }
    }
    # Pass 2: makers name the chip in some titles and not others ("Realtek RTL8125 LAN driver" / "Realtek LAN
    # Driver"). When a vendor has exactly one named chip in a category, its unnamed entries are that chip too.
    foreach ($e in $entries) {
        if (-not $e.Chip) {
            $named = @($entries | Where-Object { $_.Category -eq $e.Category -and $_.Vendor -eq $e.Vendor -and $_.Chip } | ForEach-Object { $_.Chip } | Select-Object -Unique)
            if ($named.Count -eq 1) { $e.Chip = $named[0] }
        }
    }
    # Pass 3: newest entry per category + vendor + chip.
    $groups = @{}
    foreach ($e in $entries) {
        $key = '{0}|{1}|{2}' -f $e.Category, $e.Vendor, $e.Chip
        if (-not $groups.ContainsKey($key) -or (ConvertTo-Ver $e.Version) -gt (ConvertTo-Ver $groups[$key].Version)) { $groups[$key] = $e }
    }
    $out = @($groups.Values)
    foreach ($g in $out) { $g.Sole = (@($out | Where-Object { $_.Category -eq $g.Category -and $_.Vendor -eq $g.Vendor }).Count -eq 1) }
    return $out
}

# The installed drivers (objects with DeviceName, DeviceClass, Manufacturer, DriverProviderName) that a
# board-maker listing entry applies to. When the maker lists several chips from one vendor, a device is
# only matched if its name contains the chip model; otherwise nothing is returned rather than a guess.
function Find-BoardDriverMatch($group, $drivers) {
    $wifi = 'Wi-?Fi|Wireless|802\.11|WLAN'
    $cand = @($drivers | Where-Object {
            $d = $_; $n = [string]$d.DeviceName; $classOk = $false
            if ($group.Category -eq 'LAN') { $classOk = $d.DeviceClass -eq 'NET' -and $n -notmatch ($wifi + '|Bluetooth|Virtual|WAN Miniport|TAP|VPN|Hyper-V|Loopback') }
            elseif ($group.Category -eq 'Wireless') { $classOk = $d.DeviceClass -eq 'NET' -and $n -match $wifi -and $n -notmatch 'Virtual|Direct' }
            elseif ($group.Category -eq 'Bluetooth') { $classOk = $d.DeviceClass -eq 'BLUETOOTH' }
            elseif ($group.Category -eq 'Audio') { $classOk = $d.DeviceClass -eq 'MEDIA' }
            $classOk -and (('{0} {1} {2}' -f $d.Manufacturer, $d.DriverProviderName, $n) -match $group.Vendor)
        })
    if ($group.Chip) {
        $exact = @($cand | Where-Object { ([string]$_.DeviceName) -match [regex]::Escape($group.Chip) })
        if ($exact.Count -gt 0) { return $exact }
    }
    if ($group.Sole) { return $cand }
    return @()
}

# ------------------------------------------------------------------------------------------------
# Unexpected power losses (Windows stopped with no crash record)

function Format-Duration([double]$minutes) {
    if ($minutes -lt 0) { return '' }
    if ($minutes -lt 1) { return 'under 1 min' }
    if ($minutes -lt 60) { return ('{0:N0} min' -f $minutes) }
    if ($minutes -lt 1440) { return ('{0:N0} h {1:N0} min' -f [math]::Floor($minutes / 60), ($minutes % 60)) }
    return ('{0:N0} d {1:N0} h' -f [math]::Floor($minutes / 1440), [math]::Floor(($minutes % 1440) / 60))
}

# What the PC was doing when it stopped, from the events logged before the last sign of life.
#   asleep        - it had gone to sleep or hibernated and had not woken
#   shutting-down - a shutdown or restart had been requested
#   starting-up   - it had been running for under three minutes
#   in-use        - none of the above
# $sessionStart may be $null when the boot that began the session is older than the log window.
function Get-PowerLossState([datetime]$lastAlive, $sessionStart, $sleeps, $wakes, $shutdowns) {
    $from = $lastAlive.AddDays(-30); if ($sessionStart) { $from = [datetime]$sessionStart }
    $to = $lastAlive.AddMinutes(1)
    $lastSleep = @($sleeps | Where-Object { $null -ne $_ -and $_ -ge $from -and $_ -le $to } | Sort-Object -Descending) | Select-Object -First 1
    $lastWake = @($wakes | Where-Object { $null -ne $_ -and $_ -ge $from -and $_ -le $to } | Sort-Object -Descending) | Select-Object -First 1
    if ($lastSleep -and (-not $lastWake -or $lastSleep -gt $lastWake)) { return 'asleep' }
    if (@($shutdowns | Where-Object { $null -ne $_ -and $_ -ge $lastAlive.AddMinutes(-10) -and $_ -le $to }).Count -gt 0) { return 'shutting-down' }
    if ($sessionStart -and ($lastAlive - [datetime]$sessionStart).TotalMinutes -lt 3) { return 'starting-up' }
    return 'in-use'
}

# Returns @(short label, what it means). Deliberately names no component: on their own these events are
# not evidence against any particular part.
function Get-PowerLossDescription([string]$state) {
    switch ($state) {
        'asleep' { return @('Power lost while asleep', 'The PC had gone to sleep and never woke. Either mains power was removed while it slept (switched off at the wall, a power cut) or it failed to wake and was powered off by hand. This is not evidence of a fault during use.') }
        'shutting-down' { return @('Power lost during shutdown', 'A shutdown or restart had started but did not finish. Typically a shutdown that hung and was ended with the power button, or power switched off at the wall before Windows had finished.') }
        'starting-up' { return @('Power lost during start-up', 'The PC stopped within three minutes of starting. A failed or interrupted boot.') }
    }
    return @('Power lost while in use', 'Windows stopped without recording anything while the PC was running. The logs cannot tell apart a mains cut, the reset or power button, a hard freeze, a thermal shutdown and a power-supply fault.')
}

# Overall reading of the power losses. A component is named as a suspect ONLY when this report holds
# evidence for it: out-of-tolerance voltage readings for the PSU, hardware error records for the
# CPU / memory / board, graphics driver resets for the GPU.
# Returns a hashtable: Sev, Title, Detail, Action for the Crashes section; PsuSev, PsuTitle, PsuDetail
# for the Power supply section.
function Get-PowerLossSummary($states, [bool]$railEvidence, [int]$withHardwareErrors, [int]$withGpuResets, [bool]$railsReadable) {
    $n = @($states).Count
    $inUse = @($states | Where-Object { $_ -eq 'in-use' }).Count
    $asleep = @($states | Where-Object { $_ -eq 'asleep' }).Count
    $shut = @($states | Where-Object { $_ -eq 'shutting-down' }).Count
    $start = @($states | Where-Object { $_ -eq 'starting-up' }).Count
    $parts = @()
    if ($inUse) { $parts += ('{0} while in use' -f $inUse) }
    if ($asleep) { $parts += ('{0} while asleep' -f $asleep) }
    if ($shut) { $parts += ('{0} during shutdown' -f $shut) }
    if ($start) { $parts += ('{0} during start-up' -f $start) }
    $breakdown = $parts -join ', '
    $r = @{}
    if ($inUse -eq 0 -and $start -eq 0) {
        $r.Sev = 'info'
        $r.Title = ('{0} unexpected power loss(es), none while the PC was in use' -f $n)
        $r.Detail = ('Breakdown: {0}. This pattern is what switching the PC off at the wall, a power cut, or powering off by hand after a failed wake or a hung shutdown looks like. Nothing here indicates a hardware fault during use.' -f $breakdown)
        $r.Action = 'If nobody is switching it off at the mains, the thing to look at is sleep and shutdown rather than hardware: update the chipset and graphics drivers and try turning off Fast Startup.'
        $r.PsuSev = 'info'
        $r.PsuTitle = ('{0} unexpected power loss(es) recorded, none while the PC was in use' -f $n)
        $r.PsuDetail = 'See the Crashes section for the timeline. Losses while asleep or shutting down are not evidence against the power supply.'
        return $r
    }
    $bad = $inUse + $start
    $r.Sev = 'warn'; if ($bad -ge 3) { $r.Sev = 'crit' }
    $r.Title = ('{0} unexpected power loss(es) while the PC was running (of {1} in total)' -f $bad, $n)
    $evidence = @()
    if ($railEvidence) { $evidence += 'Voltage readings in this report are outside tolerance, which makes the power supply a credible suspect.' }
    if ($withHardwareErrors -gt 0) { $evidence += ('{0} of them are accompanied by hardware error records, which point at CPU or memory stability or the motherboard.' -f $withHardwareErrors) }
    if ($withGpuResets -gt 0) { $evidence += ('{0} of them followed graphics driver resets, which point at the graphics card, its driver or its power feed.' -f $withGpuResets) }
    if ($evidence.Count -eq 0) { $evidence += 'This report holds no evidence pointing at any one component, so none is named.' }
    $r.Detail = ('Breakdown: {0}. Windows recorded nothing at the moment of failure, so the logs alone cannot tell a mains cut, the power or reset button, a hard freeze, a thermal shutdown and a power-supply fault apart. {1}' -f $breakdown, ($evidence -join ' '))
    if ($railsReadable) { $r.Action = 'Note what the PC was doing each time (the timeline shows when). Then run watch mode during that activity: it records voltage rails, temperatures and power draw while you use the PC, which is the evidence that separates these causes.' }
    else { $r.Action = 'Note what the PC was doing each time (the timeline shows when). This report has no temperature or voltage readings, which is the evidence that would separate these causes: get the sensors working (see the Motherboard section), then run watch mode during that activity.' }
    if ($railEvidence) {
        $r.PsuSev = 'warn'
        $r.PsuTitle = ('The power supply is a credible suspect for {0} power loss(es) while running' -f $bad)
        $r.PsuDetail = 'Two things line up: the PC lost power while running with no crash record, and voltage readings in this report are outside tolerance. Confirm the readings in the BIOS before replacing anything.'
    } else {
        $r.PsuSev = 'info'
        $r.PsuTitle = ('{0} power loss(es) while running: nothing in this report ties them to the power supply' -f $bad)
        $r.PsuDetail = 'A power-supply fault is one possible cause among several and can be neither confirmed nor ruled out here. It would take voltage readings outside tolerance, or a 12 V rail that sags under load in watch mode, to make it a suspect.'
    }
    return $r
}

# ------------------------------------------------------------------------------------------------
# Smaller judgements

# Percentage of an SSD's rated life consumed, or $null when nothing trustworthy reports it.
# NVMe drives publish "Percentage Used"; SATA drives publish remaining life ("Life" or "Remaining Life").
# Windows' own wear counter is only a fallback: on SATA drives it commonly reads 0 whatever the truth.
function Get-DriveLifeUsed($driveSensors, $windowsWear, [string]$busType) {
    $pu = $driveSensors | Where-Object { $_.Type -eq 'Level' -and $_.Name -match 'Percentage Used' } | Select-Object -First 1
    if ($pu) { return [double]$pu.Value }
    $rl = $driveSensors | Where-Object { $_.Type -eq 'Level' -and $_.Name -match '^(Remaining )?Life$' } | Select-Object -First 1
    if ($rl) { return [double](100 - $rl.Value) }
    if ($null -eq $windowsWear) { return $null }
    if ([double]$windowsWear -eq 0 -and $busType -ne 'NVMe') { return $null }
    return [double]$windowsWear
}

function Get-DriveAgeNote([double]$powerOnHours) {
    if ($powerOnHours -lt 40000) { return '' }
    return ('{0:N0} hours powered on, about {1:N1} years of continuous running' -f $powerOnHours, ($powerOnHours / 8766))
}

# Free space is judged on gigabytes as well as percentage: 8 % free of a 4 TB drive is plenty.
# Only the Windows drive can be critical, because only a full Windows drive stops the PC working.
function Get-FreeSpaceSeverity([double]$freeBytes, [double]$sizeBytes, [bool]$isSystem) {
    $gb = $freeBytes / 1GB; $pct = 100 * $freeBytes / $sizeBytes
    if ($isSystem) {
        if ($gb -lt 10) { return 'crit' }
        if ($gb -lt 25 -or $pct -lt 5) { return 'warn' }
        return 'ok'
    }
    if ($gb -lt 10 -or $pct -lt 5) { return 'warn' }
    return 'ok'
}

# Module maker from the part number when the module itself does not say.
function Get-MemoryMaker([string]$maker, [string]$part) {
    $m = $maker.Trim()
    if ($m -and $m -notmatch '^(Unknown|Undefined|0+|[0-9A-Fa-f]{4})$') { return $m }
    $p = $part.Trim()
    if ($p -match '^CM[A-Z]') { return 'Corsair' }
    if ($p -match '^F[345]-') { return 'G.Skill' }
    if ($p -match '^(KF|KHX|KVR|KCP)') { return 'Kingston' }
    if ($p -match '^(BL|CT)\d') { return 'Crucial' }
    if ($p -match '^(TF|TED|TLZ)') { return 'TeamGroup' }
    if ($p -match '^(PV|PSD)') { return 'Patriot' }
    if ($p -match '^(AX|AD)\d') { return 'ADATA' }
    if ($p -match '^M3[0-9A-Z]{2}[A-Z]') { return 'Samsung' }
    if ($p -match '^HM[A-Z]') { return 'SK hynix' }
    return 'Not reported'
}

# Antivirus definition updates arrive several times a day and install themselves; they are not "pending updates".
function Test-RoutineUpdate([string]$title) { return ($title -match 'Security Intelligence Update|Definition Update for (Microsoft|Windows) Defender') }

# A graphics driver only slightly behind is a note; one that has been left for months is a warning.
function Get-GpuDriverSeverity([double]$driverAgeDays) { if ($driverAgeDays -le 60) { return 'info' } return 'warn' }

# "NVIDIA Display Driver Update (32.0.16.1088)" -> "32.0.16.1088"
function Get-VersionFromTitle([string]$title) {
    $m = [regex]::Matches($title, '\d+\.\d+\.\d+\.\d+')
    if ($m.Count -gt 0) { return $m[$m.Count - 1].Value }
    return ''
}

# The installed driver that a Windows Update driver offer would replace, or nothing when that cannot be
# worked out. Matching is by vendor and device class, so it is only attempted for classes where one PC
# normally has one such device from a vendor (sound, display, network, Bluetooth).
function Find-OfferedDriverTarget([string]$title, [string]$class, $drivers) {
    $vendor = ''
    foreach ($v in 'Realtek', 'NVIDIA', 'Advanced Micro Devices|AMD', 'Intel', 'MediaTek', 'Qualcomm', 'Broadcom', 'Marvell') { if ($title -match ('^({0})\b' -f $v)) { $vendor = $v; break } }
    if (-not $vendor) { return }
    $token = $class
    if ($title -match ' - ([A-Za-z]+) - ') { $token = $Matches[1] }
    $want = ''
    if ($token -match '^(Sound|Audio|MEDIA)$') { $want = 'MEDIA' }
    elseif ($token -match '^Display$') { $want = 'DISPLAY' }
    elseif ($token -match '^Net(work)?$') { $want = 'NET' }
    elseif ($token -match '^Bluetooth$') { $want = 'BLUETOOTH' }
    if (-not $want) { return }
    return ($drivers | Where-Object {
            $_.DeviceClass -eq $want -and $_.DriverProviderName -notmatch '^Microsoft' -and $_.DriverDate -and
            (('{0} {1}' -f $_.Manufacturer, $_.DriverProviderName) -match $vendor) -and ([string]$_.DeviceName) -notmatch 'Virtual'
        } | Sort-Object { [datetime]$_.DriverDate } -Descending | Select-Object -First 1)
}

# Software-created display, network and USB devices. They are legitimate, but they sit in the same driver
# stacks as the real hardware and are worth knowing about when chasing instability or black screens.
function Test-VirtualDevice($driver) {
    if ([string]$driver.DriverProviderName -match '^Microsoft') { return $false }
    if ($driver.DeviceClass -notin 'DISPLAY', 'NET', 'USB') { return $false }
    return (('{0} {1}' -f $driver.DeviceName, $driver.DriverProviderName) -match 'Virtual|Parsec|TeamViewer|OpenVPN|TAP-Windows|WireGuard|Wintun|Sunshine|spacedesk|Duet|VPN')
}

# ------------------------------------------------------------------------------------------------
# Comparing this run with the previous one

# A finding's identity across runs: numbers are blanked so "3 warning(s)" and "4 warning(s)" are the same finding.
function Get-FindingKey([string]$area, [string]$title) { return ('{0}|{1}' -f $area, ($title -replace '\d+([.,:]\d+)*', '#')) }

# Name/value pairs of either a hashtable or an object read back from JSON.
function Get-SnapProps($o) {
    if ($null -eq $o) { return @() }
    if ($o -is [System.Collections.IDictionary]) { return @($o.Keys | ForEach-Object { [pscustomobject]@{ Name = [string]$_; Value = $o[$_] } }) }
    return @($o.PSObject.Properties | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Value = $_.Value } })
}
function Get-SnapProp($o, [string]$name) {
    $p = Get-SnapProps $o | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if ($p) { return $p.Value }
    return $null
}

# What changed between two snapshots. Both are plain data (see the snapshot built in Get-PCHealth.ps1):
#   generated 'yyyy-MM-dd HH:mm'; incidents, whea, tdr = lists of 'yyyy-MM-dd HH:mm|what' strings;
#   drives = { key: { name, lifeUsed, writtenGB, hours, uncorrected, health } }; drivers = { device: version };
#   rails = { name: volts }; bios; build; findings = [ { key, title, area } ]
# Returns @{ Findings = [ @{ sev; title; detail } ]; DriverChanges = [ @(device, old, new, direction) ]; Days }
function Compare-Snapshots($prev, $cur) {
    $f = New-Object System.Collections.ArrayList
    $dc = New-Object System.Collections.ArrayList
    $days = 0.0
    try { $days = ([datetime]$cur.generated - [datetime]$prev.generated).TotalDays } catch {}
    $since = [string]$prev.generated

    # events that happened after the previous run (older ones only appear because the look-back window moved)
    foreach ($kind in @(@('incidents', 'crash or unexpected power loss', 'warn'), @('whea', 'hardware error record', 'warn'), @('tdr', 'graphics driver reset', 'warn'))) {
        $old = @(Get-SnapProp $prev $kind[0]); $now = @(Get-SnapProp $cur $kind[0])
        $new = @($now | Where-Object { $_ -and ($old -notcontains $_) -and (([string]$_).Split('|')[0] -gt $since) })
        if ($new.Count -gt 0) {
            [void]$f.Add(@{ sev = $kind[2]; title = ('{0} new {1}(s) since the last run' -f $new.Count, $kind[1]); detail = (($new | Select-Object -First 8 | ForEach-Object { ([string]$_) -replace '\|', ': ' }) -join '; ') })
        }
    }

    $pd = Get-SnapProp $prev 'drives'; $cd = Get-SnapProp $cur 'drives'
    foreach ($d in (Get-SnapProps $cd)) {
        $o = Get-SnapProp $pd $d.Name; $n = $d.Value
        if ($null -eq $o) { [void]$f.Add(@{ sev = 'info'; title = ('New drive detected: {0}' -f $n.name); detail = '' }); continue }
        if ([string]$o.health -ne [string]$n.health) { [void]$f.Add(@{ sev = 'crit'; title = ('{0}: health status changed from {1} to {2}' -f $n.name, $o.health, $n.health); detail = '' }) }
        if ($null -ne $o.uncorrected -and $null -ne $n.uncorrected -and [double]$n.uncorrected -gt [double]$o.uncorrected) {
            [void]$f.Add(@{ sev = 'warn'; title = ('{0}: uncorrected errors rose from {1} to {2}' -f $n.name, $o.uncorrected, $n.uncorrected); detail = 'A count that keeps rising between runs is the clearest early sign of a failing drive or cable.' })
        }
        if ($null -ne $o.lifeUsed -and $null -ne $n.lifeUsed) {
            $delta = [double]$n.lifeUsed - [double]$o.lifeUsed
            if ($delta -ge 1) {
                $sev = 'info'; if ($delta -ge 5) { $sev = 'warn' }
                [void]$f.Add(@{ sev = $sev; title = ('{0}: rated life used rose from {1:N0} % to {2:N0} %' -f $n.name, $o.lifeUsed, $n.lifeUsed); detail = $(if ($days -ge 1) { 'Over {0:N0} day(s).' -f $days } else { '' }) })
            }
        }
        if ($null -ne $o.writtenGB -and $null -ne $n.writtenGB -and $days -ge 1) {
            $gb = [double]$n.writtenGB - [double]$o.writtenGB
            if ($gb -ge 1 -and ($gb / $days) -ge 100) {
                [void]$f.Add(@{ sev = 'info'; title = ('{0}: {1:N0} GB written since the last run, about {2:N0} GB a day' -f $n.name, $gb, ($gb / $days)); detail = 'A high daily write rate uses up an SSD''s rated life faster. Typical home use is well under 50 GB a day.' })
            }
        }
    }
    foreach ($d in (Get-SnapProps $pd)) {
        if ($null -eq (Get-SnapProp $cd $d.Name)) { [void]$f.Add(@{ sev = 'warn'; title = ('Drive no longer detected: {0}' -f $d.Value.name); detail = 'It was present at the last run. If it was not removed on purpose, check its cables and whether it appears in the BIOS.' }) }
    }

    $pv = Get-SnapProp $prev 'drivers'
    $down = 0; $up = 0
    foreach ($d in (Get-SnapProps (Get-SnapProp $cur 'drivers'))) {
        $o = Get-SnapProp $pv $d.Name
        if ($null -eq $o -or [string]$o -eq [string]$d.Value) { continue }
        $vo = ConvertTo-Ver ([string]$o); $vn = ConvertTo-Ver ([string]$d.Value)
        $dir = 'Changed'
        if ($vo -and $vn) { if ($vn -lt $vo) { $dir = 'DOWNGRADED'; $down++ } else { $dir = 'Updated'; $up++ } }
        [void]$dc.Add(@($d.Name, [string]$o, [string]$d.Value, $dir))
    }
    if ($down -gt 0) {
        [void]$f.Add(@{ sev = 'warn'; title = ('{0} driver(s) were replaced with an OLDER version since the last run' -f $down); detail = (($dc | Where-Object { $_[3] -eq 'DOWNGRADED' } | ForEach-Object { '{0}: {1} -> {2}' -f $_[0], $_[1], $_[2] }) -join '; ') + '. Unless you rolled these back yourself, something (usually Windows Update) has overwritten a newer driver.' })
    }
    if ($up -gt 0) { [void]$f.Add(@{ sev = 'info'; title = ('{0} driver(s) were updated since the last run' -f $up); detail = 'Listed in the table below. Worth knowing if a problem started after a particular date.' }) }

    if ($prev.bios -and $cur.bios -and [string]$prev.bios -ne [string]$cur.bios) { [void]$f.Add(@{ sev = 'info'; title = ('BIOS changed from {0} to {1}' -f $prev.bios, $cur.bios); detail = 'A BIOS update resets settings such as memory profiles and fan curves to their defaults.' }) }
    if ($prev.build -and $cur.build -and [string]$prev.build -ne [string]$cur.build) { [void]$f.Add(@{ sev = 'info'; title = ('Windows build changed from {0} to {1}' -f $prev.build, $cur.build); detail = '' }) }

    $pr = Get-SnapProp $prev 'rails'
    foreach ($r in (Get-SnapProps (Get-SnapProp $cur 'rails'))) {
        $o = Get-SnapProp $pr $r.Name
        if ($null -ne $o -and [double]$o -gt 0) {
            $pct = 100 * ([double]$r.Value - [double]$o) / [double]$o
            if ([math]::Abs($pct) -ge 2) { [void]$f.Add(@{ sev = 'info'; title = ('{0} rail reads {1:N2} V; it read {2:N2} V last time ({3:+0.0;-0.0} %)' -f $r.Name, $r.Value, $o, $pct); detail = 'A steady drift in one direction over several runs is worth more attention than any single reading.' }) }
        }
    }

    $pk = @(@($prev.findings) | Where-Object { $_ } | ForEach-Object { [string]$_.key })
    $ck = @(@($cur.findings) | Where-Object { $_ } | ForEach-Object { [string]$_.key })
    $newF = @(@($cur.findings) | Where-Object { $_ -and ($pk -notcontains [string]$_.key) })
    $gone = @(@($prev.findings) | Where-Object { $_ -and ($ck -notcontains [string]$_.key) })
    if ($newF.Count -gt 0) { [void]$f.Add(@{ sev = 'warn'; title = ('{0} problem(s) reported now that were not reported last time' -f $newF.Count); detail = (($newF | Select-Object -First 8 | ForEach-Object { '[{0}] {1}' -f $_.area, $_.title }) -join '; ') }) }
    if ($gone.Count -gt 0) { [void]$f.Add(@{ sev = 'ok'; title = ('{0} problem(s) from last time are no longer reported' -f $gone.Count); detail = (($gone | Select-Object -First 8 | ForEach-Object { '[{0}] {1}' -f $_.area, $_.title }) -join '; ') }) }

    if (@($f | Where-Object { $_.sev -in 'warn', 'crit' }).Count -eq 0) {
        [void]$f.Add(@{ sev = 'ok'; title = 'Nothing has got worse since the last run'; detail = $(if ($days -ge 1) { 'Compared with the run {0:N0} day(s) ago.' -f $days } else { 'Compared with the previous run earlier today.' }) })
    }
    return @{ Findings = $f; DriverChanges = $dc; Days = $days }
}

# ------------------------------------------------------------------------------------------------
# Board makers whose driver listings cannot be read by a script

# The support page for this exact board, for a person to open in a browser. '' when the maker is not known.
function Get-BoardSupportUrl([string]$maker, [string]$product, [string]$cpuName) {
    $model = ($product -replace '\(.*?\)', '').Trim()
    if (-not $model) { return '' }
    if ($maker -match 'Micro-Star|MSI') { return ('https://www.msi.com/Motherboard/{0}/support' -f (($model -replace '[^A-Za-z0-9]+', '-').Trim('-'))) }
    if ($maker -match 'Gigabyte') { return ('https://www.gigabyte.com/Search?kw={0}' -f [uri]::EscapeDataString($model)) }
    if ($maker -match 'ASRock') {
        $platform = 'AMD'; if ($cpuName -match 'Intel') { $platform = 'Intel' }
        return ('https://www.asrock.com/mb/{0}/{1}/index.asp#Download' -f $platform, [uri]::EscapeDataString($model))
    }
    return ''
}

# The installed drivers that a board maker would supply (sound, wired and wireless network, Bluetooth).
function Select-BoardDeviceDrivers($drivers) {
    return @($drivers | Where-Object {
            $n = [string]$_.DeviceName
            $_.DeviceClass -in 'MEDIA', 'NET', 'BLUETOOTH' -and
            (('{0} {1}' -f $_.Manufacturer, $_.DriverProviderName) -match 'Realtek|Intel|MediaTek|Qualcomm|Marvell|Aquantia|Broadcom|Killer') -and
            $n -notmatch 'Virtual|WAN Miniport|Wi-Fi Direct|Hyper-V|Loopback|Enumerator|RFCOMM|Display Audio|TAP-|VPN'
        })
}
