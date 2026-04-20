# config/compute/

Scripts that run on compute nodes via `OnNodeStart` / `OnNodeConfigured` hooks.

| File | Hook | Purpose |
|------|------|---------|
| `setup-compute-node-start.sh` | `OnNodeStart` | Load `ib_umad`, install `nvlsm`, pre-start `nvidia-fabricmanager` before pcluster cinc runs — prevents Pre-NVL5 kernel panic on p6-b200 |
| `setup-compute-node.sh` | `OnNodeConfigured` | Register post-slurmd monitoring service (node_exporter EFA + DCGM), set up hostname tagging timer |
| `fix-dcgm.sh` | Manual | Restart DCGM exporter container if metrics stop — use after node recovery or Docker issues |
