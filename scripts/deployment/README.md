# scripts/deployment/

Run locally. Deploy and tear down the full cluster stack.

| File | Purpose |
|------|---------|
| `deploy-cluster-stack.sh` | Full automated deploy: CloudFormation infra + S3 sync + pcluster create. Uses `deployment/templates/environment-variables.sh`. |
| `deploy-p6b200.sh` | p6-b200 Capacity Block deploy (sanghwa, us-east-2). Auto-detects CB AZ. |
| `deploy.sh` | General deploy: S3 sync + pcluster create. Parameterized via env vars. |
| `redeploy.sh` | Full teardown + redeploy for g5 test cluster (bailey-ai, us-east-1). Hardcoded values — use as reference only. |
