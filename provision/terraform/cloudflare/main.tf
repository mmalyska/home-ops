terraform {
  cloud {
    hostname     = "app.terraform.io"
    organization = "mmalyska"
    workspaces {
      name = "cloudflare"
    }
  }

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "4.52.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "3.5.0"
    }
    doppler = {
      source = "DopplerHQ/doppler"
    }
  }
}
