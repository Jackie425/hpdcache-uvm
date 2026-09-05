# hpdcache-uvm

CVA6-configured UVM environment for HPDcache.

The implemented data path is:

`sequence -> CRI agent -> HPDcache -> CMI/AXI adapter -> memory model -> scoreboard`

The `hpdcache_cva6` configuration keeps four active CRI agents and one passive
CRI agent on the real stride-prefetch requester. The prefetch CSRs remain disabled. The
standard `hpdcache_cri_item` represents the legal CRI request space for load,
store, AMO, and CMO operations, including partial accesses, physical or VIPT
addressing, abort, `need_rsp`, cacheability, and AUTO/WB/WT policy hints. IO is
the only PMA attribute intentionally excluded for now.

The requester driver and monitor support the two-cycle VIPT protocol,
back-to-back requests, and each item's randomized pre-request cycle delay.
Every active sequencer owns a bounded TID mailbox;
single-item API sequences acquire and release TIDs through `p_sequencer`.
Sequence sources are split into a one-item base sequence, small API sequences,
worker sequences which launch API sequences concurrently, and virtual
sequences which coordinate workers across active requesters.

The scoreboard contains:

- a predictor and byte-valid reference memory for CRI responses;
- a cacheable response evaluator keyed by `{SID,TID}`;
- an in-order uncacheable CRI request/response check plus CRI-to-CMI request
  and response forwarding checks.

Configuration objects live in `testbench/config/`. The test creates one
complete `hpdcache_env_config`, including the shared PMA map, all CRI agent
configs, and the memory response config. The default PMA map always provides
cacheable and uncacheable address regions. Each item selects its write-policy
hint independently from its PMA region. The CVA6 configuration enables WB and
disables WT; the RTL coerces WT hints to WB.

The random test configures and starts one random virtual sequence. Each DV
configuration package defines the complete fixed RTL parameter set together
with `HAS_PREFETCHER`, which describes the requester topology. When enabled,
the last requester belongs to the prefetcher; otherwise all requesters belong
to the testbench. Top-level wiring and the environment derive their defaults
from that common contract. With the current `NREQUESTERS=5` topology this means
four workers, each launching 1000 one-item random API sequences, for 4000 total
requests. Requester 4 remains passive because it is owned by the stride
prefetcher.

Run with Questa:

```sh
export QUESTA_HOME=/path/to/modeltech
make test
make test CONFIG=hpdcache_cva6
make test TEST=hpdcache_random_test SEED=1
```

`make test` defaults to `TEST=hpdcache_random_test` and `SEED=random`.

The Makefile exposes two normal workflows: `test` and `regression`. Both
delegate compilation, simulation, and report generation to the Python wrappers
in `scripts/`. The `CONFIG` selector defaults to `hpdcache_cva6` and
applies to ordinary tests and regressions.
Questa-specific compile, optimization, design-load, and simulation commands
are isolated in `scripts/questa/compile.tcl` and `scripts/questa/run.tcl`.
Python handles argument parsing, job scheduling, process invocation, and report
generation. `COMPILE_TIMEOUT` and `RUN_TIMEOUT` bound wall-clock execution;
their defaults are 1800 and 3600 seconds. Each workflow checks a fingerprint of
the selected config's compile inputs and builds only when they changed. A real
compile recreates the Questa library so removed design units cannot survive in
`work`. Tests always generate their text and JSON reports. The default run
writes its artifacts under
`build/questa/hpdcache_cva6/hpdcache_random_test/`. Pass `--live` directly to
`scripts/run_test.py` when the full transcript is needed on the terminal.

Regressions are YAML testlists under `regression/`. The default smoke list can
be run with:

```sh
python3 -m pip install -r requirements.txt
make regression JOBS=4
```

Select another list with
`make regression TESTLIST=regression/nightly.yaml JOBS=8`. Select one DV
configuration with `CONFIG=<name>`, or use `CONFIG=all` to run the testlist on
every available configuration. `CONFIG=all` is rejected by the ordinary test
target. Configurations are discovered from
`config/<name>_config_pkg.sv`. A testlist uses this schema:

```yaml
schema: 1
name: smoke
defaults:
  verbosity: UVM_LOW
tests:
  - test: hpdcache_random_test
    runs: 2
```

Here `name` identifies the regression; testlists are independent of the DV
configuration. The only configuration currently present is
`hpdcache_cva6`. Each generated `test` and `seed` pair is one independently
scheduled job. The testlist specifies only the number of `runs`; the runner
chooses concrete seeds, keeps them unique for each test across all selected
configurations, and records them in the report for reproduction.
Artifacts are written under
`build/questa/regression/<regression>/<config>/<test>/<seed>/`. The
regression-level human and machine-readable summaries are `regression.rpt` and
`regression.json` in the `<regression>` directory. A new invocation clears that
regression directory before scheduling jobs. The runner returns nonzero when
any job fails or is incomplete. Each summary row includes the sequence name and
the number of checks that passed; the per-run report contains the full details.

Structured `HPDCACHE_RPT_*` records use `UVM_NONE` so they are always present.
Environment records follow report schema 1 and are validated field by field.
Stimulus records are optional and repeatable, so a test may run multiple
sequences. One test class paired with one virtual sequence remains the
recommended model. Nonfatal self-checks use stable `HPDCACHE_CHK_*` message
IDs.
Normal component summaries and third-party transaction messages use `UVM_LOW`;
additional object dumps use `UVM_MEDIUM`. The default wrapper captures all
enabled messages without echoing them. Run `scripts/run_test.py --live ...` to
mirror the transcript, or increase `--verbosity` to enable progressively more
UVM info. Warnings, errors, and fatals are not filtered by info verbosity.

The dependency-ordered compile list is in `testbench/hpdcache_uvm.f`. UVM 1.2
is used by default; set `UVM_VERSION` to select another installed version.

The base test owns the only objection pair. After stimulus completes, it waits
for agents, monitors, predictor, and both evaluators to drain. Their
`check_phase` callbacks report unmatched state, while report callbacks print
accepted, observed, predicted, compared, and outstanding counts.

The current random regression deliberately uses the item's soft load/store
default. Directed sequences can override that soft constraint on the same item
class to generate AMO and CMO requests. Active prefetch traffic, IO accesses,
error/backpressure campaigns, functional coverage, and custom SVA remain
outside this feature.
