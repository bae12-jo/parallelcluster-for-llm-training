"""
Info webapp: NGC container SW specs, AWS DLAMI versions, AMI/pcluster compatibility checker.
"""
import asyncio
import json
import re
from datetime import datetime, timezone
from typing import Optional

import boto3
import httpx
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from fastapi import FastAPI, Form, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates

app = FastAPI(root_path="/info")
templates = Jinja2Templates(directory="templates")

_cache: dict = {
    "ngc": [],
    "dlc": [],                 # AWS Deep Learning Containers
    "dlami_groups": {},
    "pcluster_amis": [],
    "pcluster_versions": [],
    "release_versions": {},
    "last_updated": None,
}
_scheduler = AsyncIOScheduler()


# ── AWS Deep Learning Containers ─────────────────────────────────────────────
DLC_REPOS = [
    ("pytorch-training",              "PyTorch Training",        "ec2"),
    ("tensorflow-training",           "TensorFlow Training",     "ec2"),
    ("huggingface-pytorch-training",  "HuggingFace PyTorch",     "ec2"),
    ("vllm",                          "vLLM",                    "ec2"),
]
DLC_ACCOUNT = "763104351884"
DLC_REGION  = "us-east-1"

DLC_PKG_LABELS = {
    "pytorch": "PyTorch", "tensorflow": "TensorFlow",
    "cuda": "CUDA", "cudnn": "cuDNN", "nccl": "NCCL",
    "efa": "EFA", "python": "Python",
    "transformer_engine": "TransformerEngine", "flash_attn": "FlashAttn",
}

async def _dlc_latest_yaml(client: httpx.AsyncClient, repo: str, platform: str) -> dict:
    """Fetch latest GPU EC2 YAML from aws/deep-learning-containers repo."""
    try:
        api_url = f"https://api.github.com/repos/aws/deep-learning-containers/contents/docs/src/data/{repo}"
        r = await client.get(api_url, headers={"Accept": "application/vnd.github.v3+json"}, timeout=10)
        files = r.json()
        if not isinstance(files, list):
            return {}
        gpu_files = sorted(
            [f["name"] for f in files if "gpu" in f["name"] and platform in f["name"] and f["name"].endswith(".yml")],
            reverse=True,
        )
        if not gpu_files:
            return {}
        raw_url = f"https://raw.githubusercontent.com/aws/deep-learning-containers/main/docs/src/data/{repo}/{gpu_files[0]}"
        yr = await client.get(raw_url, timeout=10)
        import yaml as _yaml
        return _yaml.safe_load(yr.text) or {}
    except Exception:
        return {}

async def fetch_dlc(client: httpx.AsyncClient) -> list[dict]:
    import yaml as _yaml  # noqa: F811
    results = []
    tasks = [_dlc_latest_yaml(client, repo, platform) for repo, _, platform in DLC_REPOS]
    yamls = await asyncio.gather(*tasks)
    for (repo, display, platform), data in zip(DLC_REPOS, yamls):
        if not data:
            continue
        tags = data.get("tags", [])
        latest_tag = tags[0] if tags else "—"
        sw = {}
        for pkg, label in DLC_PKG_LABELS.items():
            val = data.get("packages", {}).get(pkg) or data.get(pkg)
            if val:
                sw[label] = str(val)
        ecr_uri = f"{DLC_ACCOUNT}.dkr.ecr.{DLC_REGION}.amazonaws.com/{repo}"
        results.append({
            "name": display,
            "repo": repo,
            "ecr_uri": ecr_uri,
            "latest_tag": latest_tag,
            "recent_tags": tags[:5],
            "sw": sw,
            "url": f"https://github.com/aws/deep-learning-containers/tree/main/docs/src/data/{repo}",
        })
    return results


# ── NGC ──────────────────────────────────────────────────────────────────────
NGC_REPOS = [
    ("nvidia/pytorch",      "PyTorch"),
    ("nvidia/tensorflow",   "TensorFlow"),
    ("nvidia/tritonserver", "Triton Server"),
    ("nvidia/nemo",         "NeMo"),
    ("nvidia/cuda",         "CUDA"),
    ("nvidia/nccl-tests",   "NCCL Tests"),
]

SW_KEYS = {
    "CUDA_VERSION": "CUDA",
    "NCCL_VERSION": "NCCL",
    "PYTORCH_VERSION": "PyTorch",
    "PYTORCH_BUILD_VERSION": None,          # skip, redundant
    "NVIDIA_PYTORCH_VERSION": "NGC Release",
    "TF_VERSION": "TensorFlow",
    "TENSORFLOW_VERSION": "TensorFlow",
    "PYTHON_VERSION": "Python",
    "CUBLAS_VERSION": "cuBLAS",
    "CUDNN_VERSION": "cuDNN",
    "CUDA_DRIVER_VERSION": "Driver",
    "AWS_OFI_NCCL_VERSION": "AWS OFI NCCL",
    "OPENMPI_VERSION": "OpenMPI",
    "TRITON_SERVER_VERSION": "Triton",
    "NEMO_VERSION": "NeMo",
}


async def _ngc_token(client: httpx.AsyncClient, repo: str) -> str:
    r = await client.get(
        f"https://nvcr.io/proxy_auth?account=&scope=repository:{repo}:pull", timeout=8
    )
    return r.json().get("token", "")


def _ver_key(t: str):
    m = re.match(r"^(\d+)\.(\d+)", t)
    return (int(m.group(1)), int(m.group(2))) if m else (0, 0)


async def _fetch_sw_spec(client: httpx.AsyncClient, repo: str, tag: str, token: str) -> dict:
    """Parse ENV vars from image config blob to extract SW versions."""
    try:
        # Step 1: get config digest from manifest
        r = await client.get(
            f"https://nvcr.io/v2/{repo}/manifests/{tag}",
            headers={
                "Authorization": f"Bearer {token}",
                "Accept": "application/vnd.docker.distribution.manifest.v2+json",
            },
            timeout=15,
        )
        manifest = r.json()
        config_digest = manifest.get("config", {}).get("digest", "")
        if not config_digest:
            return {}

        # Step 2: fetch config blob — 307 redirect drops Authorization, so follow manually
        blob_url = f"https://nvcr.io/v2/{repo}/blobs/{config_digest}"
        blob_r = await client.get(
            blob_url,
            headers={"Authorization": f"Bearer {token}"},
            follow_redirects=False,
            timeout=15,
        )
        if blob_r.status_code in (301, 302, 307, 308):
            redirect_url = blob_r.headers.get("location", "")
            blob_r = await client.get(redirect_url, timeout=20)
        config = blob_r.json()
        env_vars = config.get("config", {}).get("Env", [])

        sw = {}
        for e in env_vars:
            if "=" not in e:
                continue
            k, v = e.split("=", 1)
            label = SW_KEYS.get(k)
            if label is None:
                continue
            v = re.sub(r"\+git[0-9a-f]+.*$", "", v)
            v = re.sub(r"a0\+.*$", "", v)
            sw[label] = v.strip()
        return sw
    except Exception:
        return {}


async def fetch_ngc_containers(client: httpx.AsyncClient) -> list[dict]:
    results = []
    for repo, display in NGC_REPOS:
        try:
            token = await _ngc_token(client, repo)
            r = await client.get(
                f"https://nvcr.io/v2/{repo}/tags/list?n=200",
                headers={"Authorization": f"Bearer {token}"},
                timeout=10,
            )
            if r.status_code != 200:
                continue
            tags = r.json().get("tags", [])
            ver_tags = sorted(
                [t for t in tags if re.match(r"^\d+", t)
                 and not any(x in t for x in ["sbom", "vex", "sha256"])],
                key=_ver_key, reverse=True,
            )
            # take latest non-igpu tag for SW spec
            main_tags = [t for t in ver_tags if "igpu" not in t]
            latest = main_tags[0] if main_tags else (ver_tags[0] if ver_tags else None)
            if not latest:
                continue

            sw = await _fetch_sw_spec(client, repo, latest, token)
            results.append({
                "name": display,
                "repo": repo,
                "latest_tag": latest,
                "recent_tags": ver_tags[:6],
                "sw": sw,
                "url": f"https://catalog.ngc.nvidia.com/orgs/nvidia/containers/{repo.split('/')[-1]}",
            })
        except Exception:
            continue
    return results


# ── DLAMI ────────────────────────────────────────────────────────────────────
DLAMI_PRIORITY_PATHS = [
    # (ssm_path_suffix, category, label, docs_index_slug)
    ("base-oss-nvidia-driver-gpu-ubuntu-22.04",             "Base",       "Base OSS Ubuntu 22.04",     "aws-deep-learning-x86-base-gpu-ami-ubuntu-22-04"),
    ("base-oss-nvidia-driver-gpu-ubuntu-24.04",             "Base",       "Base OSS Ubuntu 24.04",     "aws-deep-learning-x86-base-gpu-ami-ubuntu-24-04"),
    ("base-with-single-cuda-ubuntu-22.04",                  "Base",       "Single CUDA Ubuntu 22.04",  "aws-deep-learning-x86-base-with-single-cuda-ami-ubuntu-22-04"),
    ("base-with-single-cuda-ubuntu-24.04",                  "Base",       "Single CUDA Ubuntu 24.04",  "aws-deep-learning-x86-base-with-single-cuda-ami-ubuntu-24-04"),
    ("base-oss-nvidia-driver-gpu-amazon-linux-2023",        "Base",       "Base OSS AL2023",           "aws-deep-learning-x86-base-gpu-ami-amazon-linux-2023"),
    ("oss-nvidia-driver-gpu-pytorch-2.10-ubuntu-24.04",     "PyTorch",    "PyTorch 2.10 Ubuntu 24.04", "aws-deep-learning-x86-gpu-pytorch-2.10-ubuntu-24-04"),
    ("oss-nvidia-driver-gpu-pytorch-2.10-amazon-linux-2023","PyTorch",    "PyTorch 2.10 AL2023",       "aws-deep-learning-x86-gpu-pytorch-2.10-amazon-linux-2023"),
    ("oss-nvidia-driver-gpu-pytorch-2.9-ubuntu-24.04",      "PyTorch",    "PyTorch 2.9 Ubuntu 24.04",  "aws-deep-learning-x86-gpu-pytorch-2.9-ubuntu-24-04"),
    ("oss-nvidia-driver-gpu-pytorch-2.9-amazon-linux-2023", "PyTorch",    "PyTorch 2.9 AL2023",        "aws-deep-learning-x86-gpu-pytorch-2.9-amazon-linux-2023"),
    ("oss-nvidia-driver-gpu-pytorch-2.8-ubuntu-24.04",      "PyTorch",    "PyTorch 2.8 Ubuntu 24.04",  "aws-deep-learning-x86-gpu-pytorch-2.8-ubuntu-24-04"),
    ("oss-nvidia-driver-gpu-pytorch-2.8-amazon-linux-2023", "PyTorch",    "PyTorch 2.8 AL2023",        "aws-deep-learning-x86-gpu-pytorch-2.8-amazon-linux-2023"),
    ("oss-nvidia-driver-gpu-tensorflow-2.18-ubuntu-22.04",  "TensorFlow", "TF 2.18 Ubuntu 22.04",      "aws-deep-learning-x86-gpu-tensorflow-2.18-ubuntu-22-04"),
    ("oss-nvidia-driver-gpu-tensorflow-2.18-amazon-linux-2023","TensorFlow","TF 2.18 AL2023",          "aws-deep-learning-x86-gpu-tensorflow-2.18-amazon-linux-2023"),
    ("multi-framework-oss-nvidia-driver-amazon-linux-2",    "Multi",      "Multi-Framework AL2",       "aws-deep-learning-x86-multi-framework-al2"),
]

# Markdown table key → display label
DLAMI_MD_KEYS = {
    "nvidia_driver": "NVIDIA Driver",
    "framework_version": "Framework",
    "efa_version": "EFA",
    "ofi_nccl_version": "OFI NCCL",
    "nvidia_container_toolkit_version": "Container Toolkit",
    "operating_system": "OS",
    "kernel_version": "Kernel",
    "supported_ec2_instances": "Supported",
}

def _parse_dlami_markdown(md_text: str) -> dict:
    """Parse DLAMI release notes markdown table for SW versions."""
    sw = {}
    for line in md_text.split("\n"):
        # table row: |  key$1with$1spaces  |  value  |
        m = re.match(r"\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|", line)
        if not m:
            continue
        raw_key = m.group(1).replace("\\$1", "_").replace("$1", "_").strip().lower()
        raw_key = re.sub(r"[^a-z0-9_]", "_", raw_key).strip("_")
        value = m.group(2).replace("\\$1", " ").strip()
        label = DLAMI_MD_KEYS.get(raw_key)
        if label and value and value != "---":
            sw[label] = value
    return sw

async def _fetch_dlami_sw(client: httpx.AsyncClient, docs_slug: str) -> dict:
    """Fetch latest release markdown from DLAMI docs and parse SW versions."""
    try:
        index_url = f"https://docs.aws.amazon.com/dlami/latest/devguide/{docs_slug}.html"
        r = await client.get(index_url, timeout=10)
        html = r.text
        # Find latest .md link
        md_links = re.findall(r'href="(aws-deep-learning[^"]+\.md)"', html)
        if not md_links:
            return {}
        latest_md = md_links[0]
        md_url = f"https://docs.aws.amazon.com/dlami/latest/devguide/{latest_md}"
        md_r = await client.get(md_url, timeout=10)
        return _parse_dlami_markdown(md_r.text)
    except Exception:
        return {}

async def fetch_dlami_versions_async(client: httpx.AsyncClient, region: str = "us-east-1") -> dict:
    """Returns dict of {category: [ami_entries]} with SW versions from docs."""
    ssm = boto3.client("ssm", region_name=region)
    ec2 = boto3.client("ec2", region_name=region)
    groups: dict[str, list] = {}

    # Fetch all AMI IDs first (sync)
    entries_to_fetch = []
    for suffix, category, label, docs_slug in DLAMI_PRIORITY_PATHS:
        path = f"/aws/service/deeplearning/ami/x86_64/{suffix}/latest/ami-id"
        try:
            ami_id = ssm.get_parameter(Name=path)["Parameter"]["Value"]
            images = ec2.describe_images(ImageIds=[ami_id])["Images"]
            if not images:
                continue
            img = images[0]
            ami_name = img.get("Name", "")
            creation_date = img.get("CreationDate", "")[:10]
            # basic SW from name
            sw_basic = {}
            fw_m = re.search(r"(PyTorch|TensorFlow|CUDA)\s+([\d.]+)", ami_name)
            if fw_m:
                sw_basic[fw_m.group(1)] = fw_m.group(2)
            entries_to_fetch.append({
                "label": label, "category": category,
                "ami_id": ami_id, "name": ami_name,
                "creation_date": creation_date,
                "sw": sw_basic, "docs_slug": docs_slug,
            })
        except Exception:
            continue

    # Fetch SW details from docs in parallel
    async def enrich(entry):
        if entry["docs_slug"]:
            sw_extra = await _fetch_dlami_sw(client, entry["docs_slug"])
            entry["sw"].update(sw_extra)
        return entry

    enriched = await asyncio.gather(*[enrich(e) for e in entries_to_fetch])
    for entry in enriched:
        groups.setdefault(entry["category"], []).append(entry)
    return groups

def fetch_dlami_versions(region: str = "us-east-1") -> dict:
    """Sync wrapper — called from non-async context in refresh_cache."""
    return {}  # replaced by async version below


# ── pcluster + HyperPod ───────────────────────────────────────────────────────
GITHUB_RELEASES = [
    ("aws/aws-parallelcluster",    "ParallelCluster"),
    ("aws/sagemaker-hyperpod-cli", "HyperPod CLI"),
]

async def fetch_release_versions(client: httpx.AsyncClient) -> dict[str, list]:
    """Fetch GitHub releases for pcluster and HyperPod CLI."""
    result = {}
    for repo, label in GITHUB_RELEASES:
        try:
            r = await client.get(
                f"https://api.github.com/repos/{repo}/releases?per_page=8",
                headers={"Accept": "application/vnd.github.v3+json"},
                timeout=10,
            )
            releases = r.json()
            if not isinstance(releases, list):
                continue
            result[label] = [
                {
                    "version": rel["tag_name"].lstrip("v"),
                    "date": rel["published_at"][:10],
                    "url": rel["html_url"],
                }
                for rel in releases
                if not rel.get("prerelease", False)
            ][:6]
        except Exception:
            result[label] = []
    return result

async def fetch_pcluster_versions(client: httpx.AsyncClient) -> list[dict]:
    """Kept for backward compat — returns pcluster list only."""
    versions = await fetch_release_versions(client)
    return versions.get("ParallelCluster", [])


# ── Compatibility check ───────────────────────────────────────────────────────
def _resolve_ami(ami_id: str, region: str) -> dict:
    ec2 = boto3.client("ec2", region_name=region)
    images = ec2.describe_images(ImageIds=[ami_id])["Images"]
    if not images:
        return {}
    img = images[0]
    name = img.get("Name", "")
    sw = {}
    fw_m = re.search(r"(PyTorch|TensorFlow|CUDA)\s+([\d.]+)", name)
    if fw_m:
        sw[fw_m.group(1)] = fw_m.group(2)
    name_lower = name.lower()
    if "ubuntu" in name_lower:
        sw["OS"] = "ubuntu2204" if "22.04" in name_lower else "ubuntu2404" if "24.04" in name_lower else "ubuntu"
    elif "amzn2023" in name_lower or "amazon linux 2023" in name_lower:
        sw["OS"] = "alinux2023"
    elif "amzn2" in name_lower:
        sw["OS"] = "alinux2"
    tags = {t["Key"]: t["Value"] for t in img.get("Tags", [])}
    return {
        "ami_id": ami_id,
        "name": name,
        "creation_date": img.get("CreationDate", "")[:10],
        "architecture": img.get("Architecture", ""),
        "sw": sw,
        "tags": tags,
    }

def _resolve_container(image_ref: str) -> dict:
    """Parse nvcr.io container image ref and extract SW info from cache."""
    ngc = _cache.get("ngc", [])
    for c in ngc:
        repo = c.get("repo", "")
        if repo in image_ref:
            tag_m = re.search(r":([^@\s]+)$", image_ref)
            tag = tag_m.group(1) if tag_m else c.get("latest_tag", "")
            return {
                "name": c.get("name", ""),
                "repo": repo,
                "tag": tag,
                "sw": c.get("sw", {}),
                "is_latest": tag == c.get("latest_tag"),
            }
    return {"name": image_ref, "repo": "", "tag": "", "sw": {}, "is_latest": None}

def check_compatibility(ami_id: str, container_image: str,
                        pcluster_version: str = "", region: str = "us-east-1") -> dict:
    result = {
        "ami": None, "container": None,
        "pcluster_version": pcluster_version,
        "warnings": [], "compatible": None,
        "summary": [],
    }
    try:
        # Resolve AMI
        if ami_id:
            ami_info = _resolve_ami(ami_id.strip(), region)
            if not ami_info:
                result["warnings"].append(f"AMI {ami_id} not found in {region}.")
            else:
                result["ami"] = ami_info
                pc_ver = ami_info["tags"].get("parallelcluster:version")
                if pc_ver:
                    result["summary"].append(f"AMI is official pcluster v{pc_ver} image.")
                    if pcluster_version and pc_ver != pcluster_version:
                        result["warnings"].append(
                            f"AMI built for pcluster v{pc_ver} but you specified v{pcluster_version}."
                        )

        # Resolve container
        if container_image:
            c_info = _resolve_container(container_image.strip())
            result["container"] = c_info
            if c_info.get("is_latest") is False:
                result["summary"].append(
                    f"Container tag {c_info['tag']} is not the latest "
                    f"({_cache.get('ngc', [{}])[0].get('latest_tag', '?')} available)."
                )

        # Cross-check: CUDA driver compatibility
        ami_sw = (result["ami"] or {}).get("sw", {})
        cont_sw = (result["container"] or {}).get("sw", {})
        ami_driver = ami_sw.get("NVIDIA Driver", "")
        cont_cuda = cont_sw.get("CUDA", "")
        if ami_driver and cont_cuda:
            # CUDA 13.x requires driver >= 570; CUDA 12.x >= 525
            cuda_major = int(cont_cuda.split(".")[0]) if cont_cuda else 0
            driver_ver = float(ami_driver.split(".")[0]) if ami_driver else 0
            min_driver = {13: 570, 12: 525, 11: 450}.get(cuda_major, 0)
            if driver_ver >= min_driver:
                result["summary"].append(
                    f"Driver {ami_driver} supports CUDA {cont_cuda} ✓"
                )
            else:
                result["warnings"].append(
                    f"Driver {ami_driver} may be too old for CUDA {cont_cuda} (need >= {min_driver}.x)."
                )

        # pcluster version check
        if pcluster_version:
            ver_m = re.match(r"(\d+)\.(\d+)", pcluster_version)
            if ver_m:
                major, minor = int(ver_m.group(1)), int(ver_m.group(2))
                if major < 3:
                    result["warnings"].append("ParallelCluster 2.x is end-of-life.")
                elif major == 3 and minor < 12:
                    result["warnings"].append(
                        f"pcluster {pcluster_version} is older — latest is 3.15.0."
                    )

        result["compatible"] = len(result["warnings"]) == 0
    except Exception as e:
        result["warnings"].append(f"Error: {e}")
    return result

# keep old signature for backward compat
def check_ami_compatibility(ami_id: str, pcluster_version: str, region: str = "us-east-1") -> dict:
    r = check_compatibility(ami_id, "", pcluster_version, region)
    ami = r.get("ami") or {}
    return {
        "ami_id": ami_id, "pcluster_version": pcluster_version,
        "ami_found": bool(ami), "ami_name": ami.get("name", ""),
        "ami_description": "", "ami_creation_date": ami.get("creation_date", ""),
        "os": ami.get("sw", {}).get("OS", ""), "architecture": ami.get("architecture", ""),
        "tags": ami.get("tags", {}), "sw": ami.get("sw", {}),
        "warnings": r["warnings"], "compatible": r["compatible"],
    }


# ── background refresh ────────────────────────────────────────────────────────
def _parse_pcluster_ami_sw(description: str) -> dict:
    """Extract SW versions from pcluster AMI description string."""
    sw = {}
    if not description:
        return sw
    for pkg, label in [
        ("nvidia", "NVIDIA Driver"), ("cuda", "CUDA"),
        ("efa", "EFA"), ("lustre", "Lustre"), ("dcv", "DCV"), ("kernel", "Kernel"),
    ]:
        m = re.search(pkg + r"-([\d.]+)", description, re.IGNORECASE)
        if m:
            sw[label] = m.group(1)
    return sw

async def fetch_pcluster_amis(region: str = "us-east-1") -> list[dict]:
    """Fetch official pcluster AMIs (latest 2 versions, x86_64 only) with SW specs."""
    try:
        from collections import defaultdict
        ec2 = boto3.client("ec2", region_name=region)
        images = ec2.describe_images(
            Owners=["247102896272"],
            Filters=[{"Name": "name", "Values": ["aws-parallelcluster-3.*x86_64*"]}],
        )["Images"]
        by_version: dict = defaultdict(list)
        for img in images:
            m = re.match(r"aws-parallelcluster-([\d.]+)-([\w-]+?)-hvm-x86_64", img.get("Name", ""))
            if m:
                ver, os_name = m.group(1), m.group(2)
                sw = _parse_pcluster_ami_sw(img.get("Description", ""))
                by_version[ver].append({
                    "os": os_name,
                    "ami_id": img["ImageId"],
                    "name": img.get("Name", ""),
                    "creation_date": img.get("CreationDate", "")[:10],
                    "sw": sw,
                })
        sorted_versions = sorted(
            by_version.keys(),
            key=lambda v: tuple(int(x) for x in v.split(".")), reverse=True
        )[:2]
        result = []
        for ver in sorted_versions:
            result.append({
                "version": ver,
                "amis": sorted(by_version[ver], key=lambda x: x["os"]),
            })
        return result
    except Exception:
        return []


async def refresh_cache():
    async with httpx.AsyncClient() as client:
        ngc, dlc, release_versions, dlami_groups = await asyncio.gather(
            fetch_ngc_containers(client),
            fetch_dlc(client),
            fetch_release_versions(client),
            fetch_dlami_versions_async(client),
        )
    pcluster_amis = await fetch_pcluster_amis()
    _cache["ngc"] = ngc
    _cache["dlc"] = dlc
    _cache["dlami_groups"] = dlami_groups
    _cache["pcluster_amis"] = pcluster_amis
    _cache["pcluster_versions"] = release_versions.get("ParallelCluster", [])
    _cache["release_versions"] = release_versions
    _cache["last_updated"] = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")


@app.on_event("startup")
async def startup():
    _scheduler.add_job(refresh_cache, "interval", hours=6, next_run_time=datetime.now())
    _scheduler.start()

@app.on_event("shutdown")
async def shutdown():
    _scheduler.shutdown()


# ── routes ───────────────────────────────────────────────────────────────────
@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    return templates.TemplateResponse("index.html", {
        "request": request, **_cache, "check_result": None,
    })

@app.post("/check", response_class=HTMLResponse)
async def check(
    request: Request,
    ami_id: str = Form(default=""),
    container_image: str = Form(default=""),
    pcluster_version: str = Form(default=""),
    region: str = Form("us-east-1"),
):
    result = check_compatibility(
        ami_id.strip(), container_image.strip(),
        pcluster_version.strip(), region.strip()
    )
    return templates.TemplateResponse("index.html", {
        "request": request, **_cache, "check_result": result,
    })

@app.get("/refresh")
async def manual_refresh():
    await refresh_cache()
    return {"status": "ok", "last_updated": _cache["last_updated"]}

@app.get("/api/ngc")
async def api_ngc():
    return _cache["ngc"]

@app.get("/api/dlc")
async def api_dlc():
    return _cache["dlc"]

@app.get("/api/dlami")
async def api_dlami():
    return _cache["dlami_groups"]

@app.get("/api/pcluster_amis")
async def api_pcluster_amis(region: str = "us-east-1"):
    if region == "us-east-1":
        return _cache["pcluster_amis"]
    return await fetch_pcluster_amis(region=region)

@app.get("/api/recommended_amis")
async def api_recommended_amis(platform: str = "pcluster", version: str = "", region: str = "us-east-1"):
    """Return recommended AMIs for a given platform+version combination."""
    if platform == "pcluster":
        amis = _cache["pcluster_amis"] if region == "us-east-1" else await fetch_pcluster_amis(region=region)
        if version:
            amis = [v for v in amis if v["version"] == version]
        result = []
        for v in amis[:2]:
            for a in v["amis"]:
                result.append({
                    "label": f"[pcluster-{v['version']}-{a['os']}] {a['ami_id']}",
                    "ami_id": a["ami_id"],
                    "type": "pcluster",
                    "version": v["version"],
                    "os": a["os"],
                    "sw": a.get("sw", {}),
                    "recommended": True,
                })
        # also add DLAMI options
        for cat, entries in _cache["dlami_groups"].items():
            for d in entries:
                result.append({
                    "label": f"[dlami-{d['label']}] {d['ami_id']}",
                    "ami_id": d["ami_id"],
                    "type": "dlami",
                    "version": d["label"],
                    "sw": d.get("sw", {}),
                    "recommended": False,
                })
        return result
    elif platform == "hyperpod":
        # HyperPod: recommend DLAMI Base OSS GPU, then others
        result = []
        for cat, entries in _cache["dlami_groups"].items():
            for d in entries:
                is_base = "Base" in d["label"]
                result.append({
                    "label": f"[dlami-{d['label']}] {d['ami_id']}",
                    "ami_id": d["ami_id"],
                    "type": "dlami",
                    "version": d["label"],
                    "sw": d.get("sw", {}),
                    "recommended": is_base,
                })
        result.sort(key=lambda x: (not x["recommended"], x["label"]))
        return result
    return []
