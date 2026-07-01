resource "runpod_pod" "training" {
  count = var.enable_runpod ? 1 : 0

  name         = var.runpod_pod_name
  image_name   = var.runpod_image
  gpu_type_ids = var.runpod_gpu_type_ids
  gpu_count    = var.runpod_gpu_count
  cloud_type   = var.runpod_cloud_type

  container_disk_in_gb = var.runpod_container_disk_gb

  # Expose SSH port
  ports = ["22/tcp"]

  env = {
    FACESWAP_BACKEND = "nvidia"
    KERAS_BACKEND    = "torch"
  }

  # Attach a persistent network volume when runpod_volume_gb > 0
  volume_in_gb     = var.runpod_volume_gb > 0 ? var.runpod_volume_gb : null
  volume_mount_path = var.runpod_volume_gb > 0 ? "/workspace" : null
}
