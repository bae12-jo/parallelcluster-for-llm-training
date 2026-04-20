# config/AMI/

Scripts for building a custom AMI with p6-b200 prerequisites baked in.
Run once on a builder instance (g4dn.2xlarge recommended), then snapshot.

| File | Purpose |
|------|---------|
| `build-p6b200-ami.sh` | Full AMI build: installs `ib_umad`, `nvlsm`, enables `nvidia-fabricmanager`. Run on a pcluster 3.15 official AMI instance. |
