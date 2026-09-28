# the-database-was-not-busy

An Azure SQL Database held flat against a hard platform write limit, reporting
**8% CPU** while it happened — and the sentence in the title, which is what
somebody says to close a performance ticket, is true and irrelevant.

## The problem

Azure SQL Database meters how fast you may generate transaction log. The ceiling
is set by your service tier, it is enforced whatever your schema and your
indexes look like, and when you reach it your writes simply stop getting faster.

None of the signals anyone actually checks will tell you that is what happened:

- *Is the CPU high?* No. Measured at **7.37–8.37%** while the write channel was
  full.
- *Is data IO high?* No. **0%**.
- *Is there a missing index?* No, and adding three made it worse.
- *Is the query slow?* It is — but the **fastest** workload in this lab is the
  throttled one, and the slowest is not throttled at all.

The one metric that does report it, `avg_log_write_percent`, is not on the
portal's default blade. The ceiling itself is written down in exactly one place
and it is a DMV.

## What this proves

Three write workloads against one free serverless database, graded against
[`throttle-matrix.json`](throttle-matrix.json), which was written **after**
measuring the platform and **before** the graded runs.

| phase | what it is | throughput | peak log write | peak CPU |
|---|---|---|---|---|
| `paced` | 600k rows in 30 batches, one second apart | 3.75–3.81 MB/s | **27.6–51.7%** | 3.3–5.1% |
| `saturated` | 1.8M wide rows, one statement, minimal schema | **19.06–19.23 MB/s** | **97.9–100%** | 7.4–8.4% |
| `indexHeavy` | 1.2M rows into a table with three nonclustered indexes | 14.76–16.65 MB/s | 73.1–99.0% | **16.7–24.8%** |

| | |
|---|---|
| Log ceiling on this tier | **18.00 MB/s**, read from `sys.dm_user_db_resource_governance` |
| Guards | 2, plus 7 assertions — 9 graded outcomes |
| Unit tests | 32, no database required |
| Ideas the measurements refused | **7** |
| Cost | nothing — the Azure SQL Database free offer, permanently free |

## The result

```
   paced       peak log 40.07%  peak cpu 4.46%   3.80 MB/s   not throttled
   saturated   peak log 98.12%  peak cpu 7.82%  19.12 MB/s   THROTTLED
   indexHeavy  peak log 88.16%  peak cpu 21.51% 14.76 MB/s   (not graded, see below)

   paced-is-not-throttled                          Unthrottled  as declared
   saturated-is-throttled                          Throttled    as declared
   cpu-stays-idle-while-throttled                  True         as declared
   indexes-multiply-the-log-for-identical-rows      True         as declared
   log-write-percent-does-report-it                True         as declared
   throughput-does-not-indicate-throttling         True         as declared
   index-maintenance-moves-the-cost-to-cpu         True         as declared
   the-dmv-is-still-filling-in-after-the-workload  True         as declared
   the-cap-is-only-in-a-dmv                        True         as declared

   9/9 as declared; 0 failed; 0 inconclusive.
```

**Read the CPU column.** The throttled phase used 7.82% of its CPU allowance
while its write channel was reported at 98%. A dashboard, an alert rule and a
default portal blade would all describe that database as idle.

## Two things that are backwards

**Slow does not mean throttled.** The throttled phase is the *fastest* of the
three, at 19 MB/s, and the unthrottled control is the *slowest*, at 3.8 MB/s —
five times slower and nowhere near the ceiling. Reaching a rate limit requires
going fast. So "the load is slow, it must be throttled" is close to the
opposite of the truth, and it is the reason people buy a bigger tier for a
problem that was a schema.

**Fixing the schema can move the bottleneck rather than remove it.** Adding
three nonclustered indexes costs **3.4× the transaction log for identical rows**
— 0.203 KB per row into a minimal table against 0.684 KB with the indexes — and
takes CPU from 8% to over 20%. Against a fixed write ceiling, log volume *is*
elapsed time. So indexes are the lever that exists here, and the same change
that reduces log pressure increases CPU pressure.

## What is not asserted, and why

`indexHeavy` is measured on every run and its throttle state is **never
graded**. Across six correctly-attributed runs its peak log write read 73.08%,
85.91%, 88.16%, 90.98%, 96.71% and 98.97% — it straddles the saturation
threshold, and on one run it exceeded the phase that is *supposed* to be the
saturated one. Index maintenance makes log generation bursty, so the phase
genuinely sometimes hits the ceiling and sometimes does not.

Two earlier versions of this matrix asserted first a verdict about that phase
and then an *ordering* between it and the saturated phase. Each was declared
stable on the strength of two runs, and a third run refused both. What is
asserted now are only the two quantities that never moved: it is consistently
slower, and it consistently uses more CPU.

The threshold is 90% and the two graded phases clear it by **8 and 38 points**.
That margin, rather than the number of green runs, is the reason to believe them.

## Why the evidence has to be a sampled percentage

`Resolve-ThrottleOutcome` grades on `avg_log_write_percent` and takes the
presence of samples as a separate input from their value, which is the whole
design:

| outcome | meaning |
|---|---|
| `Throttled` | the platform reported the log channel at or above saturation |
| `Unthrottled` | samples arrived and showed headroom |
| `Unknown` | could not be determined. Always a failure, never a pass |

`sys.dm_db_resource_stats` aggregates in 15-second buckets and lags the
workload, so reading it too early returns `0.00` for every column. **Zero and
"not collected yet" are the same number with opposite meanings** — one says the
database had headroom, the other says nobody looked in time. Without tracking
sample presence separately, the grader would report a failed measurement as a
healthy database.

Two things are deliberately *not* used as the primary signal:

**`LOG_RATE_GOVERNOR` wait time.** It was **0 ms in every flat-out phase**. The
governor paces smoothly at the ceiling and only charges wait time when a caller
overshoots it, so a zero wait is not evidence of headroom. It is used only to
*add* a `Throttled` verdict, never to remove one.

**A rate computed from `sys.dm_io_virtual_file_stats`.** One run measured
21.57 MB/s against an 18.00 MB/s ceiling. A rate above the ceiling proves that
number is not the quantity being metered — probably bytes written including
padding rather than log generated. It is reported as colour, never graded.

All the judgement lives in
[`LogRateGovernor`](module/LogRateGovernor/LogRateGovernor.psm1), which touches
no database and is covered by 32 unit tests.

## Cost

**Nothing.** The Azure SQL Database free offer is permanent — *"for the lifetime
of your subscription"* — not a 12-month trial: up to 10 General Purpose
databases per subscription, each with 100,000 vCore-seconds of serverless
compute, 32 GB of data and 32 GB of backup storage a month. Overspend is opt-in,
and the default on exhausting the allowance is to auto-pause until the next
month.

A full drill run costs roughly 600 vCore-seconds, so the monthly allowance is
about 160 runs.

For contrast, the **SQL Managed Instance** free offer is 12 months, one instance,
and after it expires the instance and every database in it are deleted within 30
days. It also excludes failover groups, zone redundancy and long-term backup
retention. For a lab like this one, SQL Database is the better platform and it is
not close.

## Running it

```bash
scripts/bootstrap.sh
pwsh ./scripts/Invoke-ThrottleDrill.ps1 -Server <the name it prints> -Database lograte
```

The bootstrap creates a logical server with **Entra-only authentication** — no
SQL password exists anywhere in this lab — and one free serverless database. The
drill creates its own tables, measures, grades and drops them. Pass `-Keep` to
leave them behind.

Two things the bootstrap does that look like paranoia and are not:

**It walks a list of regions.** East US and East US 2 both answered
`RegionDoesNotAllowProvisioning` for a new logical server on the same day Central
US accepted one. No published list predicts this.

**It uses a fresh server name per attempt.** A half-failed create reserves the
name at the ARM level while `az sql server list` shows nothing at all, so
retrying the same name in another region fails with `InvalidResourceLocation` and
looks like a region problem when it is a name collision.

Note that the free offer fixes **one region per subscription** at first creation.
Whichever region succeeds is the region for every free database you make after
it.

## Bugs the build found in itself

**The premise was measured before it was written down, and the first design did
not survive it.** Verifying the mechanism took one insert: 200,000 rows, 3,147 ms,
**1,620 ms of `LOG_RATE_GOVERNOR` wait — 51% of the elapsed time**. That was the
signal the lab was possible. Everything after it was corrections.

**The control was not a control.** The first design used a small minimal-schema
insert and expected it to be unthrottled. Measured at 19.56 MB/s and 100% log
write: on an 18 MB/s ceiling, *any* flat-out bulk write saturates the channel,
and small is not the same as under the limit. The control has to be paced in
time — a design rejected earlier for looking artificial, and in fact the only
honest one.

**A six-second phase read the saturation of the thirty-second phase after it.**
Each phase's sample window is widened past its end to catch a straddling bucket,
and with phases running back-to-back the widening reached into the next one. The
control graded `Throttled` on a workload that was nowhere near the ceiling. Fixed
with a quiet gap longer than the widening. An earlier hand-measurement had
50-second gaps by accident, which is the only reason it never showed this.

**A saturated phase reported itself unsaturated.** A 21.8-second write at
18.84 MB/s against an 18.00 MB/s ceiling peaked at **90.46%** — clearing a 90%
threshold by less than half a point — because a 15-second bucket containing the
ramp-up or the tail averages the saturation down. Lengthened rather than
loosening the threshold: a guard that passes by 0.46 points is not a guard.

**A ratio that inflated with row count.** The log-volume assertion compared raw
totals, so doubling a phase's size would have turned a genuine 3.4× into a
reported 6.7× — the assertion would have *passed more emphatically* while
measuring something false. Changed to per-row before that happened.

**And the one that is not about SQL.** `indexHeavy` was asserted as unthrottled,
then as throttled, then as an ordering against another phase. Each claim was
made from **two runs** and each was refused by a third. The second fix was the
first mistake at one remove: replacing a flaky verdict with a flaky ordering.
Worse, the measurement used to justify calling it throttled was a reading already
known to be contaminated by the window bleed above — the contamination and the
rewrite happened in the same run, and the expectation was changed before the
measurement was repaired.

That is the same error this lab is about, committed by the person writing it: a
number was trusted because it was the number available, not because it was sound.

## What this does not do

**It does not tune anything.** There is no remediation phase, because for a
genuinely log-bound write with a minimal schema **there is no query-side fix**.
Minimal logging does not exist on Azure SQL — the database is always in the FULL
recovery model — and PAGE compression measured a 3.9% log reduction on realistic
text. The answer is fewer log bytes or a bigger tier, and knowing which before
you spend a sprint is the point.

**It does not measure a read workload.** The log rate governor only meters
writes. A read-heavy database has different ceilings, in different DMV columns.

**It does not exercise the ceiling moving.** The limit scales with vCores —
9 MB/s floor, 18 MB/s at four — and a cold serverless database really is
throttled harder than a warm one. Demonstrating that needs control over scaling
that the free offer's 4-vCore maximum does not give.

**One tier, one SLO.** Everything here is `GP_S_Gen5` at 4 vCores. The mechanism
is general; the numbers are not.
