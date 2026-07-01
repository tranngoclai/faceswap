# ── VastAI training instance ──────────────────────────────────────────────────
# Rents the cheapest GPU offer selected in data.tf and starts a Docker container.
# SSH access is enabled so Ansible can reach the instance after provisioning.
#
# Resource docs:
#   https://registry.terraform.io/providers/realnedsanders/vastai/latest/docs/resources/instance
#
# After `terraform apply`, Ansible reads `vast_ssh_host` / `vast_ssh_port` from
# outputs and writes them to group_vars/cloud.yml alongside `cc_instance_id`.

resource "vastai_instance" "training" {
  count = var.enable_vast ? 1 : 0

  # Offer selected by the primary/fallback search in data.tf
  offer_id = local.vast_offer.id

  # Docker image pulled when the instance starts.
  # Must include CUDA libraries compatible with the host GPU driver.
  image = var.vast_image

  # Disk quota for the container filesystem (datasets + model checkpoints)
  disk_gb = var.vast_disk_gb

  # Label shown in the VastAI console and billing dashboard
  label = var.vast_label

  # Enable SSH daemon inside the container so Ansible can connect.
  # Disabling this leaves the instance accessible only via Jupyter.
  use_ssh = true

  # SSH public keys injected into the container's authorized_keys.
  # Empty set = all keys on the VastAI account are injected (account default).
  ssh_key_ids = var.vast_ssh_key_ids

  # Lightweight bootstrap script executed once after the container starts.
  # Heavy setup (faceswap install, rclone, cron) runs via Ansible playbooks.
  # Set to null to skip (Ansible handles everything after SSH is up).
  onstart = var.vast_onstart

  # Environment variables available to all processes inside the container.
  # Faceswap reads FACESWAP_BACKEND at startup; Keras reads KERAS_BACKEND.
  env = {
    FACESWAP_BACKEND = "nvidia"
    KERAS_BACKEND    = "torch"
  }

  # Increase create timeout: pulling large Docker images on cold hosts can take
  # several minutes, and the instance must reach `running` status before Ansible
  # can connect.
  timeouts {
    create = "10m"
  }
}
