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
      version = "4.36.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "3.4.3"
    }
    doppler = {
      source = "DopplerHQ/doppler"
    }
  }
}

data "cloudflare_zone" "domain" {
  name = local.cloudflare_domain
}
