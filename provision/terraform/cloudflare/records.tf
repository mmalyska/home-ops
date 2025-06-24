resource "cloudflare_dns_record" "root" {
  name    = local.cloudflare_domain
  zone_id = data.cloudflare_zone.domain.id
  content   = cloudflare_record.ingress.hostname
  proxied = true
  type    = "CNAME"
  ttl     = 1
}

resource "cloudflare_dns_record" "grocy" {
  name    = "grocy"
  zone_id = data.cloudflare_zone.domain.id
  content   = cloudflare_record.ingress.hostname
  proxied = true
  type    = "CNAME"
  ttl     = 1
}

resource "cloudflare_dns_record" "hass" {
  name    = "hass"
  zone_id = data.cloudflare_zone.domain.id
  content   = cloudflare_record.ingress.hostname
  proxied = true
  type    = "CNAME"
  ttl     = 1
}

resource "cloudflare_dns_record" "l" {
  name    = "l"
  zone_id = data.cloudflare_zone.domain.id
  content   = cloudflare_record.ingress.hostname
  proxied = true
  type    = "CNAME"
  ttl     = 1
}

resource "cloudflare_dns_record" "oauth" {
  name    = "oauth"
  zone_id = data.cloudflare_zone.domain.id
  content   = cloudflare_record.ingress.hostname
  proxied = true
  type    = "CNAME"
  ttl     = 1
}

resource "cloudflare_dns_record" "doppler" {
  name    = local.doppler_domain
  zone_id = data.cloudflare_zone.domain.id
  content   = local.doppler_value
  type    = "TXT"
  ttl     = 1
}

resource "cloudflare_dns_record" "chat" {
  name    = "chat"
  zone_id = data.cloudflare_zone.domain.id
  content   = cloudflare_record.ingress.hostname
  proxied = true
  type    = "CNAME"
  ttl     = 1
}
