resource "cloudflare_dns_record" "doppler" {
  name    = local.doppler_domain
  zone_id = cloudflare_zone.domain.id
  content = local.doppler_value
  type    = "TXT"
  ttl     = 1
}
