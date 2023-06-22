provider "cloudflare" {
  email   = local.cloudflare_email
  api_key = local.cloudflare_apikey
}

provider "doppler" {
  doppler_token = var.doppler_terraform_key
}

provider "doppler" {
  alias = "home-ops"
  doppler_token = var.doppler_homeops_key
}
