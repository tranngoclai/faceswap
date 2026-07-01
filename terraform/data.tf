# ── VastAI offer discovery ────────────────────────────────────────────────────
# Primary GPU search
data "vastai_gpu_offers" "primary" {
  count = var.enable_vast ? 1 : 0

  gpu_name            = var.vast_gpu
  num_gpus            = 1
  max_price_per_hour  = var.vast_max_price_per_hour
  order_by            = "dph_total"
  limit               = 5
}

# Fallback GPU search — used when primary returns no offers
data "vastai_gpu_offers" "fallback" {
  count = var.enable_vast ? 1 : 0

  gpu_name            = var.vast_gpu_fallback
  num_gpus            = 1
  max_price_per_hour  = var.vast_max_price_per_hour
  order_by            = "dph_total"
  limit               = 5
}

locals {
  # Pick primary if any offers exist, else fall back
  vast_offer = var.enable_vast ? (
    length(data.vastai_gpu_offers.primary[0].offers) > 0
    ? data.vastai_gpu_offers.primary[0].most_affordable
    : data.vastai_gpu_offers.fallback[0].most_affordable
  ) : null
}
