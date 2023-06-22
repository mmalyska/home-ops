data "doppler_secrets" "this" {
  project = "terraform"
  config  = "terraform_cloudflare"
}

locals {
  cloudflare_email  = data.doppler_secrets.this.map.CLOUDFLARE_EMAIL
  cloudflare_apikey = data.doppler_secrets.this.map.CLOUDFLARE_APIKEY
  cloudflare_domain = data.doppler_secrets.this.map.CLOUDFLARE_DOMAIN
  cloudflare_tunnel_secret = data.doppler_secrets.this.map.CLOUDFLARE_TUNNEL_SECRET
  doppler_domain    = data.doppler_secrets.this.map.DOPPLER_DOMAIN
  doppler_value     = data.doppler_secrets.this.map.DOPPLER_VALUE
}
