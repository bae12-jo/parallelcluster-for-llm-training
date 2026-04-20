# scripts/debugging/

Run locally via AWS CLI/SSM. Inspect and diagnose cluster state.

| File | Purpose |
|------|---------|
| `monitor-compute-node-setup.sh` | Stream compute node bootstrap logs in real time via SSM. Useful during `pcluster create-cluster` to watch `OnNodeConfigured` progress. |
