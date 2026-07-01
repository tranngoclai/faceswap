terraform {
  required_version = ">= 1.5"

  required_providers {
    vastai = {
      source  = "realnedsanders/vastai"
      version = "~> 0.3"
    }
    runpod = {
      source  = "decentralized-infrastructure/runpod"
      version = "~> 1.0"
    }
  }
}

provider "vastai" {
  api_key = var.vast_api_key
}

provider "runpod" {
  api_key = var.runpod_api_key
}
