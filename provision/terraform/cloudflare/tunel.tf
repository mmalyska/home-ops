resource "cloudflare_tunnel" "jaskinia" {
  account_id = cloudflare_account.main.id
  name       = "Jaskinia"
  secret     = local.cloudflare_tunnel
}
