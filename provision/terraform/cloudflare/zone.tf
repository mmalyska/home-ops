data "cloudflare_zone" "domain" {
  name = local.cloudflare_domain
}
