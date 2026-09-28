<#
    Grading for the log rate governance drill.

    Nothing here touches SQL. Every number is passed in, so the judgement can be
    tested without a database and a change to the grading cannot quietly depend
    on the state of one.

    Two rules this module exists to enforce, both of them learned by measuring
    rather than reasoning:

    1. Elapsed time is not evidence of throttling. A slow load can be slow for
       a dozen reasons, so the outcome is decided by what the platform reported
       about its own limits, never by a stopwatch.

    2. A zero wait time is not evidence of NOT being throttled. A workload
       sustaining 94% of the log ceiling was measured with 0 ms of
       LOG_RATE_GOVERNOR wait -- the governor paces smoothly right up to the
       limit and only registers waits once a caller overshoots it. So the log
       write percentage is the primary signal and the wait is corroboration.
#>

Set-StrictMode -Version Latest

function Get-ThrottleMatrix {
    <#
        .SYNOPSIS
        Reads throttle-matrix.json and fails loudly if it is incoherent.

        .DESCRIPTION
        The matrix is the yardstick. An incoherent one would make the drill
        unfalsifiable while its report still looked rigorous, so it is checked
        rather than trusted.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "Matrix not found at '$Path'." }

    $matrix = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json

    $guards = @($matrix.guards)
    if (-not $guards.Count) { throw 'The matrix declares no guards.' }

    $valid = @('Throttled', 'Unthrottled')
    foreach ($guard in $guards) {
        foreach ($field in 'id', 'severity', 'phase', 'expect') {
            if (-not $guard.PSObject.Properties.Name.Contains($field)) {
                throw "Guard '$($guard.id)' is missing '$field'."
            }
        }
        if ($guard.expect -notin $valid) {
            throw "Guard '$($guard.id)' expects '$($guard.expect)', which is not one of: $($valid -join ', ')."
        }
    }

    $duplicates = @(@($guards.id) | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name)
    if ($duplicates.Count) { throw "Duplicate guard id(s): $($duplicates -join ', ')." }

    $phases = @($matrix.phases.id)
    foreach ($guard in $guards) {
        if ($guard.phase -notin $phases) {
            throw "Guard '$($guard.id)' names phase '$($guard.phase)', which is not declared. Declared: $($phases -join ', ')."
        }
    }

    if (-not @($guards | Where-Object { $_.severity -eq 'Baseline' }).Count) {
        throw 'The matrix declares no Baseline guard. Without one, a drill that reports Throttled for everything passes the finding for free.'
    }

    # A matrix where every guard expects the same thing cannot distinguish a
    # working drill from one that returns a constant.
    if (@($guards.expect | Sort-Object -Unique).Count -lt 2) {
        throw 'Every guard expects the same outcome, so the matrix cannot tell a working drill from one that always answers the same way.'
    }

    foreach ($field in 'saturatedLogWritePercent', 'idleCpuPercent') {
        if (-not $matrix.thresholds.PSObject.Properties.Name.Contains($field)) {
            throw "The matrix is missing threshold '$field'."
        }
    }

    # The three phases are not interchangeable: the contrast between them is the
    # lab. A matrix that lost the unthrottled-but-slower phase would still look
    # reasonable and would no longer be able to tell a platform limit from a
    # schema problem, which is the only thing this drill really decides.
    $needed = @('paced', 'saturated', 'indexHeavy')
    $missing = @($needed | Where-Object { $_ -notin $phases })
    if ($missing.Count) {
        throw "The matrix is missing phase(s): $($missing -join ', '). Each one is load-bearing; see the phase notes in throttle-matrix.json."
    }

    return $matrix
}

function Resolve-ThrottleOutcome {
    <#
        .SYNOPSIS
        Decides whether one phase was held at the log rate ceiling.

        .DESCRIPTION
        Throttled     the platform reported the log write channel at or above
                      the saturation threshold, or charged real governor wait
        Unthrottled   samples arrived and showed headroom
        Unknown       could not be determined. Always a failure, never a pass

        SamplesFound is separate from LogWritePercent on purpose, and it is the
        most important parameter here. sys.dm_db_resource_stats aggregates in
        15-second buckets and lags behind the workload, so reading it too early
        returns 0.00 for every column. Zero and "not yet collected" are the same
        number and opposite meanings: one says the database had headroom, the
        other says nobody looked in time. Without SamplesFound this function
        would grade a failed measurement as a healthy database.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        # [object], not [bool]: a [bool] parameter coerces $null to $false, which
        # would turn "never recorded" into "no samples" and then into a verdict.
        [Parameter(Mandatory)][AllowNull()][object] $SamplesFound,

        # [object] rather than [double] for the same reason -- a numeric type
        # would coerce $null to 0, and 0 is a meaningful reading here.
        [Parameter(Mandatory)][AllowNull()][object] $LogWritePercent,

        [Parameter()][AllowNull()][object] $GovernorWaitMs,
        [Parameter()][AllowNull()][object] $ElapsedMs,
        [Parameter(Mandatory)][double] $SaturatedLogWritePercent
    )

    if ($null -eq $SamplesFound) {
        return [pscustomobject]@{
            Outcome = 'Unknown'
            Reason  = 'Whether any resource-statistics samples were collected was never recorded. Because an empty reading and a healthy reading are both zero, this cannot be defaulted either way.'
        }
    }

    if (-not [bool]$SamplesFound) {
        return [pscustomobject]@{
            Outcome = 'Unknown'
            Reason  = 'No resource-statistics samples covered this workload. sys.dm_db_resource_stats lags the workload by several 15-second buckets, so this is what reading too early looks like -- not a database with headroom.'
        }
    }

    if ($null -eq $LogWritePercent) {
        return [pscustomobject]@{
            Outcome = 'Unknown'
            Reason  = 'Samples were collected but the log write percentage was not read out of them.'
        }
    }

    $logPercent = [double]$LogWritePercent

    if ($logPercent -ge $SaturatedLogWritePercent) {
        return [pscustomobject]@{
            Outcome = 'Throttled'
            Reason  = "The log write channel reached $logPercent%, at or above the $SaturatedLogWritePercent% saturation threshold."
        }
    }

    # Corroboration, not the primary test. Governor wait can be zero at the
    # ceiling, so it can only ever add a Throttled verdict, never remove one.
    if ($null -ne $GovernorWaitMs -and $null -ne $ElapsedMs) {
        $wait = [double]$GovernorWaitMs
        $elapsed = [double]$ElapsedMs
        if ($elapsed -gt 0 -and ($wait / $elapsed) -ge 0.05) {
            $share = [math]::Round(100 * $wait / $elapsed, 1)
            return [pscustomobject]@{
                Outcome = 'Throttled'
                Reason  = "The log write channel peaked at only $logPercent%, but the governor charged ${wait}ms of wait across a ${elapsed}ms run, which is $share% of it."
            }
        }
    }

    return [pscustomobject]@{
        Outcome = 'Unthrottled'
        Reason  = "The log write channel peaked at $logPercent%, below the $SaturatedLogWritePercent% saturation threshold, with no material governor wait."
    }
}

function Resolve-Bottleneck {
    <#
        .SYNOPSIS
        Names which resource actually constrained a phase.

        .DESCRIPTION
        This is the judgement the lab exists to demonstrate. A database can be
        saturated on one channel and idle on every other, and the answer decides
        whether somebody spends a week rewriting a query that was never the
        problem.

        Returns Log, Cpu, Both, Neither or Unknown.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowNull()][object] $CpuPercent,
        [Parameter(Mandatory)][AllowNull()][object] $LogWritePercent,
        [Parameter(Mandatory)][double] $SaturatedLogWritePercent,
        [Parameter(Mandatory)][double] $IdleCpuPercent
    )

    if ($null -eq $CpuPercent -or $null -eq $LogWritePercent) {
        return [pscustomobject]@{
            Bottleneck = 'Unknown'
            Reason     = 'One of the two readings is missing, and naming a bottleneck from a single channel is how the wrong thing gets optimised.'
        }
    }

    $cpu = [double]$CpuPercent
    $log = [double]$LogWritePercent

    $logSaturated = $log -ge $SaturatedLogWritePercent
    $cpuBusy = $cpu -gt $IdleCpuPercent

    if ($logSaturated -and -not $cpuBusy) {
        return [pscustomobject]@{
            Bottleneck = 'Log'
            Reason     = "Log write at $log% with CPU at $cpu%. The database is against the log ceiling while the metric most people check reports it as idle."
        }
    }
    if ($logSaturated -and $cpuBusy) {
        return [pscustomobject]@{
            Bottleneck = 'Both'
            Reason     = "Log write at $log% and CPU at $cpu%. Both channels are under pressure, so the log ceiling is not the only thing to fix."
        }
    }
    if ($cpuBusy) {
        return [pscustomobject]@{
            Bottleneck = 'Cpu'
            Reason     = "CPU at $cpu% with log write at only $log%."
        }
    }
    return [pscustomobject]@{
        Bottleneck = 'Neither'
        Reason     = "CPU at $cpu% and log write at $log%. Neither channel is constrained, so a slow run here is slow for some other reason."
    }
}

function Test-GuardExpectation {
    <#
        .SYNOPSIS
        Compares one observed outcome against what the matrix declared.

        .DESCRIPTION
        Unknown is never a pass. A drill that could not read its own result must
        not report success, which is why the matrix refuses Unknown as a
        declarable expectation in the first place.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string] $Expected,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][object] $Observed
    )

    $seen = if ($null -eq $Observed) { '' } else { ([string]$Observed).Trim() }

    if ($seen -eq '' -or $seen -eq 'Unknown') {
        return [pscustomobject]@{
            Passed       = $false
            Inconclusive = $true
            Detail       = "Expected '$Expected' and the outcome could not be determined."
        }
    }
    if ($seen -eq $Expected) {
        return [pscustomobject]@{ Passed = $true; Inconclusive = $false; Detail = "Observed '$seen' as declared." }
    }
    return [pscustomobject]@{ Passed = $false; Inconclusive = $false; Detail = "Expected '$Expected', observed '$seen'." }
}

Export-ModuleMember -Function Get-ThrottleMatrix, Resolve-ThrottleOutcome, Resolve-Bottleneck, Test-GuardExpectation
