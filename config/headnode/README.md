# config/headnode/

Scripts that run on the HeadNode, either via `OnNodeConfigured` hook or manually post-deployment.

| File | When | Purpose |
|------|------|---------|
| `setup-headnode.sh` | `OnNodeConfigured` | Install node_exporter (:9100), queue slurm_exporter build, set up compute tagging cron |
| `install-slurm-exporter.sh` | Post-boot (auto via systemd oneshot) | Build slurm_exporter from source (Go ~10 min). Also embedded in `setup-headnode.sh`. |
| `slurm-node-reason-collector.sh` | Cron every 30s | Write `slurm_node_state_reason` Prometheus textfile metric |
| `tag-compute-nodes.sh` | Cron every 1 min | Tag compute EC2 instances with `slurm:hostname` via sinfo IP mapping |
| `disable-kernel-auto-update.sh` | Manual | Prevent kernel upgrades that break Lustre kernel module |
| `download-ngc-containers.sh` | Manual | Pre-pull NGC container images to FSx so compute nodes skip pull at job start |
