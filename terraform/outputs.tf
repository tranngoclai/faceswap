# ── VastAI outputs ────────────────────────────────────────────────────────────
# These outputs are read by the Ansible playbook `cloud-provision-instance.yml`
# and written to group_vars/cloud.yml so subsequent playbooks can reach the
# instance without re-running Terraform.

output "vast_instance_id" {
  description = "VastAI contract/instance ID — written to cloud.yml as cc_instance_id"
  value       = var.enable_vast ? vastai_instance.training[0].id : null
}

output "vast_ssh_host" {
  description = "SSH hostname (SSH proxy address assigned by VastAI)"
  value       = var.enable_vast ? vastai_instance.training[0].ssh_host : null
}

output "vast_ssh_port" {
  description = "SSH port (unique per instance on the shared proxy)"
  value       = var.enable_vast ? vastai_instance.training[0].ssh_port : null
}

output "vast_machine_id" {
  description = "Host machine ID — useful for the VastAI API (e.g. labeling, renting adjacent machines)"
  value       = var.enable_vast ? vastai_instance.training[0].machine_id : null
}

output "vast_gpu_name" {
  description = "GPU model name on the provisioned host (may differ from search filter if fallback was used)"
  value       = var.enable_vast ? vastai_instance.training[0].gpu_name : null
}

output "vast_cost_per_hour" {
  description = "Actual hourly cost in USD billed for this instance"
  value       = var.enable_vast ? vastai_instance.training[0].cost_per_hour : null
}

output "vast_geolocation" {
  description = "Geographic location of the host machine (country/region reported by VastAI)"
  value       = var.enable_vast ? vastai_instance.training[0].geolocation : null
}

# ── RunPod serverless endpoint outputs ────────────────────────────────────────
output "runpod_template_id" {
  description = "RunPod template ID — set this on the endpoint in the RunPod console"
  value       = var.enable_runpod ? runpod_template.extract[0].id : null
}
