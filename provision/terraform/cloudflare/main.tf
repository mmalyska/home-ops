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
    http = {
      source  = "hashicorp/http"
      version = "3.3.0"
    }
    sops = {
      source  = "carlpett/sops"
      version = "0.7.2"
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

data "http" "ipv4" {
  url = "http://ipv4.icanhazip.com"
}
