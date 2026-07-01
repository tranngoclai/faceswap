# ── Credentials (injected via TF_VAR_* env by Ansible) ──────────────────────
variable "vast_api_key" {
  description = "VastAI API key"
  type        = string
  sensitive   = true
}

variable "runpod_api_key" {
  description = "RunPod API key"
  type        = string
  sensitive   = true
}

# ── Provider toggle ───────────────────────────────────────────────────────────
variable "enable_vast" {
  description = "Create a VastAI GPU instance"
  type        = bool
  default     = true
}

variable "enable_runpod" {
  description = "Create a RunPod GPU pod"
  type        = bool
  default     = false
}

# ── VastAI instance config ────────────────────────────────────────────────────
variable "vast_gpu" {
  description = "Primary GPU model to search (exact VastAI display name, e.g. 'RTX 4090')"
  type        = string
  default     = "RTX 4090"
}

variable "vast_gpu_fallback" {
  description = "Fallback GPU model used when the primary has no available offers"
  type        = string
  default     = "RTX 3090"
}

variable "vast_num_gpus" {
  description = "Number of GPUs per instance (filters offers; 1 is sufficient for single-GPU faceswap training)"
  type        = number
  default     = 1
}

variable "vast_gpu_ram_gb" {
  description = "Minimum GPU VRAM in GB (null = no filter). Set to 24 for RTX 4090/3090-class training."
  type        = number
  default     = null
}

variable "vast_datacenter_only" {
  description = "Restrict search to verified datacenter hosts (higher reliability, slightly higher price)"
  type        = bool
  default     = false
}

variable "vast_offer_type" {
  description = "Offer pricing model: 'on-demand' (fixed price), 'bid' (spot, interruptible), or 'reserved'."
  type        = string
  default     = "on-demand"

  validation {
    condition     = contains(["on-demand", "bid", "reserved"], var.vast_offer_type)
    error_message = "vast_offer_type must be 'on-demand', 'bid', or 'reserved'."
  }
}

variable "vast_disk_gb" {
  description = "Container disk quota in GB — this IS the /workspace volume. Training face PNGs (A+B) ~10–20 GB + model checkpoints ~5 GB + repo + deps ~5 GB. 60 GB is sufficient for a single identity pair; increase to 100+ for large datasets."
  type        = number
  default     = 60
}

variable "vast_cuda_min" {
  description = "Minimum CUDA version required on the host (enforced via raw_query filter 'cuda_max_good >= X'). Must match the requirements file used in cloud.yml (e.g. requirements_nvidia_13.txt → 12.8+)."
  type        = string
  default     = "12.8"
}

variable "vast_image" {
  description = "Docker image pulled on instance start. Must include CUDA + PyTorch matching the host driver. VastAI base image ships /venv/main with PyTorch pre-installed (used by cloud.yml as faceswap_python/faceswap_pip paths)."
  type        = string
  # vastai/pytorch maps to the VastAI-maintained PyTorch image; the host driver
  # must satisfy vast_cuda_min (enforced by raw_query in data.tf).
  default     = "vastai/pytorch"
}

variable "vast_onstart" {
  description = "Shell script executed on instance start (after Docker pull). Use for lightweight bootstrap only; heavy setup runs via Ansible."
  type        = string
  default     = null
}

variable "vast_ssh_key_ids" {
  description = "Set of VastAI SSH key IDs to inject into the instance. Defaults to all keys on the account when empty."
  type        = set(string)
  default     = []
}

variable "vast_label" {
  description = "Human-readable label shown in the VastAI console"
  type        = string
  default     = "faceswap-training"
}

variable "vast_max_price_per_hour" {
  description = "Maximum USD/hr accepted by the offer filter (hard cap, applies to both primary and fallback GPU searches)"
  type        = number
  default     = 1.50
}

# ── RunPod serverless endpoint config ────────────────────────────────────────
variable "rp_endpoint_name" {
  description = "Display name for the RunPod serverless endpoint"
  type        = string
  default     = "faceswap-extract"
}

variable "rp_image_name" {
  description = "Docker image for the RunPod serverless worker (e.g. ghcr.io/tranngoclai/faceswap-sl:1.0.11)"
  type        = string
}

variable "rp_gdrive_sa_json_b64" {
  description = "Google Drive service account JSON base64-encoded (injected via TF_VAR_rp_gdrive_sa_json_b64 from Ansible vault)"
  type        = string
  sensitive   = true
}

variable "rp_gdrive_root_folder_id" {
  description = "Google Drive root folder ID scoping the rclone gdrive remote on the worker (GDRIVE_ROOT_FOLDER_ID env var)"
  type        = string
  default     = ""
}

variable "rp_gpu_type_ids" {
  description = "RunPod GPU type names available to endpoint workers (must match RunPod API enum)"
  type        = list(string)
  default     = ["NVIDIA GeForce RTX 4090", "NVIDIA GeForce RTX 3090"]
}

variable "rp_allowed_cuda_versions" {
  description = "CUDA driver versions allowed on RunPod workers. Worker image (nvidia/cuda:12.6.3) requires driver >= 12.6. null = RunPod picks any CUDA version (matches live). Set to [\"12.6\",\"12.7\",\"12.8\",\"12.9\"] to enforce compatibility."
  type        = list(string)
  nullable    = true
  default     = null
}

variable "rp_execution_timeout_ms" {
  description = "Max milliseconds a single job can run. Covers: rclone pull from Drive + faceswap extract + dedupe + rclone push back. 200000 (3.3 min) matches live; raise to 600000+ for longer source videos."
  type        = number
  default     = 200000
}

variable "rp_gpu_count" {
  description = "Number of GPUs per worker"
  type        = number
  default     = 1
}

variable "rp_workers_min" {
  description = "Minimum workers (0 = scale to zero when idle)"
  type        = number
  default     = 0
}

variable "rp_workers_max" {
  description = "Maximum concurrent workers (live default: 1 for single-job extract runs)"
  type        = number
  default     = 1
}

variable "rp_idle_timeout" {
  description = "Seconds a worker stays alive with no jobs before scaling down"
  type        = number
  default     = 10
}

variable "rp_data_center_ids" {
  description = "Restrict workers to specific RunPod datacenters (e.g. [\"EU-NL-1\",\"EU-RO-1\"]). null = any datacenter. Pin for latency consistency or data-residency compliance."
  type        = list(string)
  default     = null
}

variable "rp_scaler_type" {
  description = "RunPod autoscaler algorithm. QUEUE_DELAY scales based on job queue wait time; REQUEST_COUNT scales on raw pending job count."
  type        = string
  default     = "QUEUE_DELAY"

  validation {
    condition     = contains(["QUEUE_DELAY", "REQUEST_COUNT"], var.rp_scaler_type)
    error_message = "rp_scaler_type must be 'QUEUE_DELAY' or 'REQUEST_COUNT'."
  }
}

variable "rp_scaler_value" {
  description = "Scaler threshold: for QUEUE_DELAY = milliseconds of queue delay before scaling up; for REQUEST_COUNT = number of queued jobs before scaling up."
  type        = number
  default     = 4
}

