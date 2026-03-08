resource "cloudflare_zero_trust_tunnel_cloudflared" "jaskinia" {
  account_id = cloudflare_account.main.id
  name       = "Jaskinia"
  tunnel_secret  = local.cloudflare_tunnel_secret
  config_src = "cloudflare"
}

data "cloudflare_zero_trust_tunnel_cloudflared_token" "jaskinia" {
  account_id = cloudflare_account.main.id
  tunnel_id = cloudflare_zero_trust_tunnel_cloudflared.jaskinia.id
}
