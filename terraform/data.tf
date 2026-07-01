# ── VastAI offer discovery ────────────────────────────────────────────────────
# Searches VastAI marketplace for available GPU offers matching the given
# constraints. `most_affordable` returns the single cheapest offer object;
# `offers` returns the full sorted list (up to `limit`).
#
# Data source docs:
#   https://registry.terraform.io/providers/realnedsanders/vastai/latest/docs/data-sources/gpu_offers

# Primary GPU search — e.g. RTX 4090
data "vastai_gpu_offers" "primary" {
  count = var.enable_vast ? 1 : 0

  gpu_name           = var.vast_gpu
  num_gpus           = var.vast_num_gpus
  gpu_ram_gb         = var.vast_gpu_ram_gb        # null = no VRAM filter
  max_price_per_hour = var.vast_max_price_per_hour
  offer_type         = var.vast_offer_type         # "on_demand" or "bid"
  datacenter_only    = var.vast_datacenter_only    # true = verified DCs only
  order_by           = "dph_total"                 # cheapest first
  limit              = 5
  # NOTE: vast_cuda_min is not enforced here — raw_query syntax for cuda_max_good
  # causes a 400 from the VastAI API. CUDA compatibility is ensured via image
  # selection (vastai/pytorch ships the matching driver stack).
}

# Fallback GPU search — used only when the primary GPU has no available offers
data "vastai_gpu_offers" "fallback" {
  count = var.enable_vast ? 1 : 0

  gpu_name           = var.vast_gpu_fallback
  num_gpus           = var.vast_num_gpus
  gpu_ram_gb         = var.vast_gpu_ram_gb
  max_price_per_hour = var.vast_max_price_per_hour
  offer_type         = var.vast_offer_type
  datacenter_only    = var.vast_datacenter_only
  order_by           = "dph_total"
  limit              = 5
}

locals {
  # Use primary GPU offer when available; fall back to secondary GPU otherwise.
  # `most_affordable` is a computed object (id, dph_total, gpu_name, etc.)
  vast_offer = var.enable_vast ? (
    length(data.vastai_gpu_offers.primary[0].offers) > 0
    ? data.vastai_gpu_offers.primary[0].most_affordable
    : data.vastai_gpu_offers.fallback[0].most_affordable
  ) : null
}
