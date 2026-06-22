resource "cloudflare_zero_trust_tunnel_cloudflared_route" "anytype" {
  account_id = cloudflare_account.main.id
  tunnel_id  = local.cloudflare_tunnel_id
  network    = "192.168.48.29/32"
  comment    = "anytype any-sync services"
}
