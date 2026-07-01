resource "vastai_instance" "training" {
  count = var.enable_vast ? 1 : 0

  offer_id = local.vast_offer.id
  image    = var.vast_image
  disk_gb  = var.vast_disk_gb
  label    = var.vast_label

  use_ssh = true

  env = {
    FACESWAP_BACKEND = "nvidia"
    KERAS_BACKEND    = "torch"
  }

  # Wait up to 10 min for the instance to become running
  timeouts {
    create = "10m"
  }
}
