# ── VastAI outputs ────────────────────────────────────────────────────────────
output "vast_instance_id" {
  description = "VastAI contract ID (stored in cloud.yml as cc_instance_id)"
  value       = var.enable_vast ? vastai_instance.training[0].id : null
}

output "vast_ssh_host" {
  description = "VastAI SSH hostname"
  value       = var.enable_vast ? vastai_instance.training[0].ssh_host : null
}

output "vast_ssh_port" {
  description = "VastAI SSH port"
  value       = var.enable_vast ? vastai_instance.training[0].ssh_port : null
}

output "vast_gpu_name" {
  description = "GPU model name on the provisioned instance"
  value       = var.enable_vast ? vastai_instance.training[0].gpu_name : null
}

output "vast_cost_per_hour" {
  description = "Hourly cost in USD"
  value       = var.enable_vast ? vastai_instance.training[0].cost_per_hour : null
}

# ── RunPod outputs ────────────────────────────────────────────────────────────
output "runpod_pod_id" {
  description = "RunPod pod ID"
  value       = var.enable_runpod ? runpod_pod.training[0].id : null
}

output "runpod_public_ip" {
  description = "RunPod pod public IP"
  value       = var.enable_runpod ? runpod_pod.training[0].public_ip : null
}

output "runpod_cost_per_hr" {
  description = "RunPod hourly cost in credits"
  value       = var.enable_runpod ? runpod_pod.training[0].cost_per_hr : null
}
