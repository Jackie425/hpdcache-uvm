# hpdcache-uvm

Minimal, CVA6-only UVM environment for HPDcache.

The initial skeleton keeps only the main transaction path:

`sequence -> requester agent -> HPDcache -> AXI adapter -> cv_dv_utils memory model -> response -> scoreboard`

The CVA6 topology is preserved rather than reduced: four active core requester
agents are instantiated, and passive requester 4 observes the real
stride-prefetch wrapper. The prefetch CSRs are currently tied disabled and the
random test only starts a sequence on requester 0. This leaves the remaining
requester and prefetch branches connected for incremental development.

The random sequence issues one constrained-random load or store on requester 0.
The requester driver itself supports continuous requests; B2B behavior is not a
separate driver mode or test type. AMO, CMO, active prefetch traffic, coverage,
custom SVA, error injection, and memory backpressure are intentionally outside
this first milestone.

Run with Questa:

```sh
export QUESTA_HOME=/path/to/modeltech
make random
```

The complete, dependency-ordered compile list is in
`testbench/hpdcache_uvm.f`; the Makefile only sets tool paths and invokes
compile, optimize, and simulation. UVM 1.2 is used by default; set
`UVM_VERSION` to override it when invoking Make.

Build artifacts and the simulation log are written under `build/questa/`.

## Phase ownership

The project-owned driver and monitor are permanent `run_phase` services, while
the imported `axi2mem` protocol workers run in `main_phase`. Tests extend
`hpdcache_base_test` and sequences extend `hpdcache_base_sequence`; concrete
tests only select and start their stimulus.

The base test owns the only objection pair in `main_phase`. After stimulus has
been issued, it asks the environment to drain with a configurable timeout. The
environment combines every active requester agent with the composite
scoreboard's `is_idle()` state, so these components never manipulate phase
objections themselves. The scoreboard contains a predictor and an evaluator;
the predictor owns a reference-model object containing the golden memory state.
Their `check_phase` callbacks still report every pending prediction or unmatched
transaction if a test times out or otherwise ends early.

## Requester driver

Each active requester uses the same FSM driver. The driver uses the UVM
`get()`/`put()` request-response model: `get()` takes a request from the
sequencer and lets its sequence continue, while `put()` returns a response to
the originating sequence after the matching DUT response is observed. The
driver has no typed sequencer handle and does not own protocol resources.

Each active requester also owns an independent `hpdcache_tid_manager`. Its
bounded mailbox atomically transfers free TIDs, so any number of sequences can
share the same manager without a separate lock. The base sequence resolves
the `hpdcache_agent_config` handle assigned directly to its sequencer in
`pre_start()`. It acquires a TID from the config-owned manager before sending a
request and enables the UVM response handler to release that TID when the
response arrives.
The sequence remains registered with its sequencer until all of its outstanding
responses have been handled. Each driver keeps a
response-routing table keyed by TID and checks request and response SIDs against
both the agent configuration and the originating request.

All requester sampling and driving uses the interface clocking blocks. During
reset the driver drives idle and returns reset responses for requests it has
already accepted, allowing their sequences to release their TIDs. It does not
stop sequences or reach into a sequencer. The agent resets its config-owned TID
manager in `reset_phase`; the scoreboard's predictor and evaluator clear their
pending protocol state there as well. The predictor also resets its internal
golden reference state, while the backing memory model resets its own memory.
