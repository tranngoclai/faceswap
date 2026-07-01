# ── RunPod serverless extract endpoint ───────────────────────────────────────
# Manages a RunPod serverless endpoint that runs face-extraction jobs.
# The worker image (ghcr.io/tranngoclai/faceswap-sl:cu126) is defined in the
# RunPod template referenced by `template_id` — image changes are deployed by
# updating the template in the RunPod console, not via Terraform.
#
# Resource docs:
#   https://registry.terraform.io/providers/runpod/runpod/latest/docs/resources/endpoint

resource "runpod_endpoint" "extract" {
  count = var.enable_runpod ? 1 : 0

  name        = var.rp_endpoint_name
  template_id = runpod_template.extract[count.index].id
  compute_type = null
  vcpu_count   = null

  # GPU selection: both models are CUDA 12.6-capable (RTX 40/30 series).
  gpu_type_ids = var.rp_gpu_type_ids
  gpu_count    = var.rp_gpu_count

  # Restrict workers to hosts with CUDA driver >= 12.6. The worker image is
  # built on nvidia/cuda:12.6.3; an older driver will fail on torch import.
  allowed_cuda_versions = var.rp_allowed_cuda_versions

  # Scaling: min=0 (scale to zero when idle), max=rp_workers_max.
  workers_min = var.rp_workers_min
  workers_max = var.rp_workers_max

  # Worker TTL: seconds a worker stays alive after its last job before shutdown.
  idle_timeout = var.rp_idle_timeout

  # Hard job timeout — covers: rclone pull + faceswap extract + dedupe + rclone push.
  # Default 600000 (10 min); increase for long source videos.
  execution_timeout_ms = var.rp_execution_timeout_ms

  # Restrict workers to specific datacenters (null = RunPod picks any).
  # Pin this to reduce cold-start latency variance across job runs.
  data_center_ids = var.rp_data_center_ids

  # Autoscaler: QUEUE_DELAY spins up a new worker when queue wait exceeds
  # rp_scaler_value ms. Pinned here to prevent RunPod from drifting the value.
  scaler_type  = var.rp_scaler_type
  scaler_value = var.rp_scaler_value

  lifecycle {
    ignore_changes = [compute_type, vcpu_count]
  }
}
