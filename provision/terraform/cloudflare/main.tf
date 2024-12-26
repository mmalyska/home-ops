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
      version = "4.49.1"
    }
    http = {
      source  = "hashicorp/http"
      version = "3.4.5"
    }
    doppler = {
      source = "DopplerHQ/doppler"
    }
  }
}
