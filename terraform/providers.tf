terraform {
  required_version = ">= 1.5"

  required_providers {
    # Community provider maintained by realnedsanders.
    # Registry: https://registry.terraform.io/providers/realnedsanders/vastai
    # Changelog: https://github.com/realnedsanders/terraform-provider-vastai/releases
    vastai = {
      source  = "realnedsanders/vastai"
      version = "~> 0.3"
    }

    # Official RunPod provider for serverless endpoint management.
    # Registry: https://registry.terraform.io/providers/runpod/runpod
    runpod = {
      source  = "runpod/runpod"
      version = "~> 1.0"
    }
  }
}

# VastAI provider — API key injected via TF_VAR_vast_api_key (set by Ansible
# from the `vast_admin_key` vault variable before calling `terraform apply`).
provider "vastai" {
  api_key = var.vast_api_key
}

# RunPod provider — API key injected via TF_VAR_runpod_api_key (set by Ansible
# from the `runpod_api_key` vault variable).
provider "runpod" {
  api_key = var.runpod_api_key
}
