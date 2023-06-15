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
      version = "4.8.0"
    }
    doppler = {
      source = "DopplerHQ/doppler"
    }
  }
}

data "cloudflare_zones" "domain" {
  filter {
    name = local.cloudflare_domain
  }
}
