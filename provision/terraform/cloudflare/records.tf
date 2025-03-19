resource "cloudflare_dns_record" "root" {
  depends_on  = [
    cloudflare_dns_record.ingress,
  ]
  name    = local.cloudflare_domain
  zone_id = cloudflare_zone.domain.id
  content   = cloudflare_dns_record.ingress.content
  proxied = true
  type    = "CNAME"
  ttl     = 1
}

resource "cloudflare_dns_record" "grocy" {
  depends_on  = [
    cloudflare_dns_record.ingress,
  ]
  name    = "grocy"
  zone_id = cloudflare_zone.domain.id
  content   = cloudflare_dns_record.ingress.content
  proxied = true
  type    = "CNAME"
  ttl     = 1
}

resource "cloudflare_dns_record" "hass" {
  depends_on  = [
    cloudflare_dns_record.ingress,
  ]
  name    = "hass"
  zone_id = cloudflare_zone.domain.id
  content   = cloudflare_dns_record.ingress.content
  proxied = true
  type    = "CNAME"
  ttl     = 1
}

resource "cloudflare_dns_record" "l" {
  depends_on  = [
    cloudflare_dns_record.ingress,
  ]
  name    = "l"
  zone_id = cloudflare_zone.domain.id
  content   = cloudflare_dns_record.ingress.content
  proxied = true
  type    = "CNAME"
  ttl     = 1
}

resource "cloudflare_dns_record" "oauth" {
  depends_on  = [
    cloudflare_dns_record.ingress,
  ]
  name    = "oauth"
  zone_id = cloudflare_zone.domain.id
  content   = cloudflare_dns_record.ingress.content
  proxied = true
  type    = "CNAME"
  ttl     = 1
}

resource "cloudflare_dns_record" "doppler" {
  depends_on  = [
    cloudflare_dns_record.ingress,
  ]
  name    = local.doppler_domain
  zone_id = cloudflare_zone.domain.id
  content   = local.doppler_value
  type    = "TXT"
  ttl     = 1
}

resource "cloudflare_dns_record" "chat" {
  depends_on  = [
    cloudflare_dns_record.ingress,
  ]
  name    = "chat"
  zone_id = cloudflare_zone.domain.id
  content   = cloudflare_dns_record.ingress.content
  proxied = true
  type    = "CNAME"
  ttl     = 1
}
