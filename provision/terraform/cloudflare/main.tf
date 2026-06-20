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
      version = "5.21.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "3.6.0"
    }
    bitwarden-secrets = {
      source  = "bitwarden/bitwarden-secrets"
      version = "1.0.0"
    }
  }
}
