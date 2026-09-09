# hpdcache-uvm

A reusable UVM verification environment for the HPDcache RTL. Its primary goal
is to provide composable Cache-Requesters Interface (CRI) and Cache-Memory
Interface (CMI) agents, sequences, monitors, reference models, and checking
components that can be reused across HPDcache configurations and verification
flows.

## Scope

The environment verifies the main HPDcache request and memory paths through
CRI and CMI traffic. It includes randomized load/store traffic, atomic tests,
protocol and response checking, reference-model comparison, transaction drain
checking, and coverage collection. These CRI and CMI names follow the
interfaces defined by the HPDcache specification.

## Requirements

- Python 3.10 or newer
- Questa/ModelSim 2020.4 with `vlog`, `vopt`, `vsim`, and `vcover` (recommended
  and validated)
- An installed UVM library, normally `$QUESTA_HOME/uvm-1.2`
- Initialized `cv-hpdcache` and `core-v-verif` submodules

Set the simulator location and install the Python dependency:

```sh
export QUESTA_HOME=/path/to/modeltech
git submodule update --init --recursive
python3 -m pip install -r requirements.txt
```

## Quick start

After setting up the requirements, run the smoke regression:

```sh
make regression
```
