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
  description = "Primary GPU model to search (exact vastai name)"
  type        = string
  default     = "RTX 4090"
}

variable "vast_gpu_fallback" {
  description = "Fallback GPU model if primary has no offers"
  type        = string
  default     = "RTX 3090"
}

variable "vast_disk_gb" {
  description = "Disk size in GB"
  type        = number
  default     = 60
}

variable "vast_cuda_min" {
  description = "Minimum CUDA version required"
  type        = string
  default     = "12.8"
}

variable "vast_image" {
  description = "Docker image for the instance"
  type        = string
  default     = "vastai/base-image"
}

variable "vast_label" {
  description = "Human-readable label for the instance"
  type        = string
  default     = "faceswap-training"
}

variable "vast_max_price_per_hour" {
  description = "Maximum USD/hr for the VastAI offer filter"
  type        = number
  default     = 1.50
}

# ── RunPod pod config ─────────────────────────────────────────────────────────
variable "runpod_pod_name" {
  description = "Name for the RunPod pod"
  type        = string
  default     = "faceswap-training"
}

variable "runpod_image" {
  description = "Docker image for the RunPod pod"
  type        = string
  default     = "runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04"
}

variable "runpod_gpu_type_ids" {
  description = "Ordered list of GPU type IDs to try (first available wins)"
  type        = list(string)
  default     = ["NVIDIA GeForce RTX 4090", "NVIDIA GeForce RTX 3090"]
}

variable "runpod_gpu_count" {
  description = "Number of GPUs"
  type        = number
  default     = 1
}

variable "runpod_container_disk_gb" {
  description = "Container disk in GB"
  type        = number
  default     = 60
}

variable "runpod_volume_gb" {
  description = "Persistent network volume in GB (0 = no volume)"
  type        = number
  default     = 0
}

variable "runpod_cloud_type" {
  description = "SECURE or COMMUNITY cloud"
  type        = string
  default     = "SECURE"
}
