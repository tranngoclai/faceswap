# ── RunPod serverless worker template ────────────────────────────────────────
# Manages the RunPod template that defines the worker image, environment, and
# disk for the faceswap-extract serverless endpoint.
#
# Resource docs:
#   https://registry.terraform.io/providers/runpod/runpod/latest/docs/resources/template

resource "runpod_template" "extract" {
  count = var.enable_runpod ? 1 : 0

  name              = "faceswap-extract"
  image_name        = var.rp_image_name
  container_registry_auth_id = ""
  container_disk_in_gb = 50
  is_public         = false
  volume_mount_path = "/workspace"
  readme            = ""

  # Worker ports: Jupyter (8888), SSH (22 tcp+udp).
  ports = ["8888/http", "22/tcp", "22/udp"]

  # Runtime environment: Cloudflare R2 credentials for rclone.
  # Secrets injected via TF_VAR_* from Ansible vault at apply time.
  env = {
    RCLONE_CONFIG_R2_TYPE              = "s3"
    RCLONE_CONFIG_R2_PROVIDER          = "Cloudflare"
    RCLONE_CONFIG_R2_ACCESS_KEY_ID     = var.rp_r2_access_key_id
    RCLONE_CONFIG_R2_SECRET_ACCESS_KEY = var.rp_r2_secret_access_key
    RCLONE_CONFIG_R2_ENDPOINT          = var.rp_r2_endpoint
    R2_BUCKET                          = var.rp_r2_bucket
  }

}
