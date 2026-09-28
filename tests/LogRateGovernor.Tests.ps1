<#
    Unit tests for the grading module. No database, no network.

    The cases that matter most are the ones asserting that an ABSENT reading is
    graded Unknown rather than healthy. sys.dm_db_resource_stats returns 0.00 for
    every column when its 15-second buckets have not landed yet, so "no
    throttling" and "nobody looked in time" arrive as the same number.
#>

BeforeAll {
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../module/LogRateGovernor/LogRateGovernor.psm1') -Force
    $script:MatrixPath = Join-Path -Path $PSScriptRoot -ChildPath '../throttle-matrix.json'

    # Scriptblocks, not functions: Pester 5 discovers and runs in separate passes
    # and functions defined in BeforeAll do not survive into the run phase, while
    # $script: variables do.
    $script:WriteMatrix = {
        param($Object)
        $path = Join-Path ([IO.Path]::GetTempPath()) ('throttle-' + [guid]::NewGuid().ToString('n') + '.json')
        $Object | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding utf8
        return $path
    }

    # All three real phases, so the rule requiring them can be tested in both
    # directions rather than only tripped by accident.
    $script:RealisticMatrix = {
        return [pscustomobject]@{
            thresholds = [pscustomobject]@{ saturatedLogWritePercent = 90; idleCpuPercent = 25 }
            phases     = @(
                [pscustomobject]@{ id = 'paced' }
                [pscustomobject]@{ id = 'saturated' }
                [pscustomobject]@{ id = 'indexHeavy' }
            )
            guards     = @(
                [pscustomobject]@{ id = 'a'; severity = 'Baseline'; phase = 'paced'; expect = 'Unthrottled' }
                [pscustomobject]@{ id = 'b'; severity = 'Critical'; phase = 'saturated'; expect = 'Throttled' }
                [pscustomobject]@{ id = 'c'; severity = 'Critical'; phase = 'indexHeavy'; expect = 'Unthrottled' }
            )
        }
    }

    $script:GoodMatrix = {
        return [pscustomobject]@{
            thresholds = [pscustomobject]@{ saturatedLogWritePercent = 90; idleCpuPercent = 25 }
            phases     = @(
                [pscustomobject]@{ id = 'underCap' }
                [pscustomobject]@{ id = 'overCap' }
            )
            guards     = @(
                [pscustomobject]@{ id = 'control'; severity = 'Baseline'; phase = 'underCap'; expect = 'Unthrottled' }
                [pscustomobject]@{ id = 'finding'; severity = 'Critical'; phase = 'overCap'; expect = 'Throttled' }
            )
        }
    }
}

Describe 'Resolve-ThrottleOutcome' {

    Context 'an absent reading is not a healthy reading' {

        It 'grades missing samples as Unknown, not Unthrottled' {
            # The case the module exists for. Reading the DMV too early returns
            # 0.00 everywhere; calling that "headroom" would invert the finding.
            $result = Resolve-ThrottleOutcome -SamplesFound $false -LogWritePercent 0 -SaturatedLogWritePercent 90
            $result.Outcome | Should -Be 'Unknown'
            $result.Reason | Should -Match 'reading too early'
        }

        It 'grades unrecorded sample presence as Unknown' {
            $result = Resolve-ThrottleOutcome -SamplesFound $null -LogWritePercent 0 -SaturatedLogWritePercent 90
            $result.Outcome | Should -Be 'Unknown'
            $result.Reason | Should -Match 'never recorded'
        }

        It 'grades samples with no log reading as Unknown' {
            (Resolve-ThrottleOutcome -SamplesFound $true -LogWritePercent $null -SaturatedLogWritePercent 90).Outcome |
                Should -Be 'Unknown'
        }

        It 'does not let a zero percentage become a pass without samples' {
            (Resolve-ThrottleOutcome -SamplesFound $false -LogWritePercent 0 -SaturatedLogWritePercent 90).Outcome |
                Should -Not -Be 'Unthrottled'
        }
    }

    Context 'the values actually measured on this SLO' {

        It 'grades 95.97 percent as Throttled' {
            $result = Resolve-ThrottleOutcome -SamplesFound $true -LogWritePercent 95.97 -SaturatedLogWritePercent 90
            $result.Outcome | Should -Be 'Throttled'
            $result.Reason | Should -Match '95\.97'
        }

        It 'grades 24.68 percent as Unthrottled' {
            (Resolve-ThrottleOutcome -SamplesFound $true -LogWritePercent 24.68 -SaturatedLogWritePercent 90).Outcome |
                Should -Be 'Unthrottled'
        }

        It 'grades exactly the threshold as Throttled' {
            (Resolve-ThrottleOutcome -SamplesFound $true -LogWritePercent 90 -SaturatedLogWritePercent 90).Outcome |
                Should -Be 'Throttled'
        }
    }

    Context 'governor wait corroborates but never overrules' {

        It 'calls a run Throttled when the governor charged over five percent of it' {
            # The 200k-row insert: 1620 ms of governor wait in a 3147 ms run,
            # while the sampled percentage had not caught up.
            $result = Resolve-ThrottleOutcome -SamplesFound $true -LogWritePercent 30 `
                -GovernorWaitMs 1620 -ElapsedMs 3147 -SaturatedLogWritePercent 90
            $result.Outcome | Should -Be 'Throttled'
            $result.Reason | Should -Match '51'
        }

        It 'ignores a trivial governor wait' {
            (Resolve-ThrottleOutcome -SamplesFound $true -LogWritePercent 30 `
                -GovernorWaitMs 8 -ElapsedMs 30000 -SaturatedLogWritePercent 90).Outcome | Should -Be 'Unthrottled'
        }

        It 'still grades Throttled on a high percentage even with zero governor wait' {
            # Measured: a workload sustaining 94% of the cap registered 0 ms of
            # wait. A zero wait must never be able to clear a saturated channel.
            (Resolve-ThrottleOutcome -SamplesFound $true -LogWritePercent 95.97 `
                -GovernorWaitMs 0 -ElapsedMs 30245 -SaturatedLogWritePercent 90).Outcome | Should -Be 'Throttled'
        }

        It 'does not divide by a zero elapsed time' {
            { Resolve-ThrottleOutcome -SamplesFound $true -LogWritePercent 10 `
                -GovernorWaitMs 100 -ElapsedMs 0 -SaturatedLogWritePercent 90 } | Should -Not -Throw
        }
    }
}

Describe 'Resolve-Bottleneck' {

    It 'names Log when the log channel is saturated and CPU is idle' {
        # The headline measurement: 8.89% CPU, 95.97% log write.
        $result = Resolve-Bottleneck -CpuPercent 8.89 -LogWritePercent 95.97 `
            -SaturatedLogWritePercent 90 -IdleCpuPercent 25
        $result.Bottleneck | Should -Be 'Log'
        $result.Reason | Should -Match 'reports it as idle'
    }

    It 'names Both when CPU is busy as well' {
        (Resolve-Bottleneck -CpuPercent 80 -LogWritePercent 95 `
            -SaturatedLogWritePercent 90 -IdleCpuPercent 25).Bottleneck | Should -Be 'Both'
    }

    It 'names Cpu when only CPU is busy' {
        (Resolve-Bottleneck -CpuPercent 90 -LogWritePercent 10 `
            -SaturatedLogWritePercent 90 -IdleCpuPercent 25).Bottleneck | Should -Be 'Cpu'
    }

    It 'names Neither when nothing is constrained' {
        (Resolve-Bottleneck -CpuPercent 3 -LogWritePercent 5 `
            -SaturatedLogWritePercent 90 -IdleCpuPercent 25).Bottleneck | Should -Be 'Neither'
    }

    It 'refuses to name a bottleneck from one channel' {
        $result = Resolve-Bottleneck -CpuPercent $null -LogWritePercent 95 `
            -SaturatedLogWritePercent 90 -IdleCpuPercent 25
        $result.Bottleneck | Should -Be 'Unknown'
        $result.Reason | Should -Match 'wrong thing gets optimised'
    }
}

Describe 'Test-GuardExpectation' {

    It 'passes when the outcome matches' {
        (Test-GuardExpectation -Expected 'Throttled' -Observed 'Throttled').Passed | Should -BeTrue
    }

    It 'fails when the outcome differs' {
        $result = Test-GuardExpectation -Expected 'Throttled' -Observed 'Unthrottled'
        $result.Passed | Should -BeFalse
        $result.Inconclusive | Should -BeFalse
    }

    It 'treats Unknown as inconclusive and not a pass' {
        $result = Test-GuardExpectation -Expected 'Throttled' -Observed 'Unknown'
        $result.Passed | Should -BeFalse
        $result.Inconclusive | Should -BeTrue
    }

    It 'treats a null outcome as inconclusive' {
        (Test-GuardExpectation -Expected 'Throttled' -Observed $null).Inconclusive | Should -BeTrue
    }
}

Describe 'Get-ThrottleMatrix' {

    It 'reads the real matrix that ships with the lab' {
        $matrix = Get-ThrottleMatrix -Path $script:MatrixPath
        @($matrix.guards).Count | Should -BeGreaterThan 0
        @($matrix.phases).Count | Should -BeGreaterThan 1
    }

    It 'requires a Baseline guard' {
        $bad = & $script:GoodMatrix
        $bad.guards[0].severity = 'Critical'
        { Get-ThrottleMatrix -Path (& $script:WriteMatrix $bad) } | Should -Throw '*no Baseline guard*'
    }

    It 'requires the guards to expect more than one outcome' {
        $bad = & $script:GoodMatrix
        $bad.guards[1].expect = 'Unthrottled'
        { Get-ThrottleMatrix -Path (& $script:WriteMatrix $bad) } | Should -Throw '*always answers the same way*'
    }

    It 'rejects an expectation that is not a real outcome' {
        $bad = & $script:GoodMatrix
        $bad.guards[1].expect = 'ProbablyFine'
        { Get-ThrottleMatrix -Path (& $script:WriteMatrix $bad) } | Should -Throw '*not one of*'
    }

    It 'rejects Unknown as an expectation' {
        $bad = & $script:GoodMatrix
        $bad.guards[1].expect = 'Unknown'
        { Get-ThrottleMatrix -Path (& $script:WriteMatrix $bad) } | Should -Throw '*not one of*'
    }

    It 'rejects a guard naming a phase that is not declared' {
        $bad = & $script:GoodMatrix
        $bad.guards[1].phase = 'sometimeLater'
        { Get-ThrottleMatrix -Path (& $script:WriteMatrix $bad) } | Should -Throw '*not declared*'
    }

    It 'rejects duplicate guard ids' {
        $bad = & $script:GoodMatrix
        $bad.guards[1].id = 'control'
        { Get-ThrottleMatrix -Path (& $script:WriteMatrix $bad) } | Should -Throw '*Duplicate guard id*'
    }

    It 'rejects a matrix with no thresholds' {
        $bad = & $script:GoodMatrix
        $bad.thresholds = [pscustomobject]@{ idleCpuPercent = 25 }
        { Get-ThrottleMatrix -Path (& $script:WriteMatrix $bad) } | Should -Throw '*saturatedLogWritePercent*'
    }

    It 'rejects a matrix with no guards' {
        $bad = & $script:GoodMatrix
        $bad.guards = @()
        { Get-ThrottleMatrix -Path (& $script:WriteMatrix $bad) } | Should -Throw '*no guards*'
    }

    It 'accepts a matrix carrying all three phases' {
        { Get-ThrottleMatrix -Path (& $script:WriteMatrix (& $script:RealisticMatrix)) } | Should -Not -Throw
    }

    It 'rejects a matrix that lost the unthrottled-but-slower phase' {
        # Losing indexHeavy would leave a matrix that still looks reasonable and
        # can no longer tell a platform limit from a schema problem.
        $bad = & $script:RealisticMatrix
        $bad.phases = @($bad.phases | Where-Object { $_.id -ne 'indexHeavy' })
        $bad.guards = @($bad.guards | Where-Object { $_.phase -ne 'indexHeavy' })
        { Get-ThrottleMatrix -Path (& $script:WriteMatrix $bad) } | Should -Throw '*missing phase*'
    }

    It 'fails loudly when the file is missing' {
        { Get-ThrottleMatrix -Path (Join-Path ([IO.Path]::GetTempPath()) 'not-here.json') } | Should -Throw '*not found*'
    }
}
