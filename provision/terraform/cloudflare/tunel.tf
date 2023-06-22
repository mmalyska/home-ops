resource "cloudflare_tunnel" "jaskinia" {
  account_id = cloudflare_account.main.id
  name       = "Jaskinia"
  secret     = local.cloudflare_tunnel_secret
}

resource "doppler_secret" "cloudflare_tunnel" {
  provider = doppler.home-ops
  project = "home-ops"
  config  = "prd"
  name = "CLOUDFLARE_TUNNEL_TOKEN"
  value = cloudflare_tunnel.jaskinia.tunnel_token
}
