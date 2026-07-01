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
  category          = "NVIDIA"
  container_disk_in_gb = 50
  is_serverless     = true
  is_public         = false
  volume_mount_path = "/workspace"
  readme            = ""

  # Worker ports: Jupyter (8888), SSH (22 tcp+udp).
  ports = ["8888/http", "22/tcp", "22/udp"]

  # Runtime environment: Google Drive service account for rclone.
  # Secrets injected via TF_VAR_* from Ansible vault at apply time.
  env = {
    GDRIVE_SA_JSON_B64   = var.rp_gdrive_sa_json_b64
    GDRIVE_ROOT_FOLDER_ID = var.rp_gdrive_root_folder_id
  }

}
