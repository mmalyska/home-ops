resource "cloudflare_dns_record" "root" {
  name    = local.cloudflare_domain
  zone_id = cloudflare_zone.domain.id
  content   = loudflare_dns_record.ingress.name
  proxied = true
  type    = "CNAME"
  ttl     = 1
}

resource "cloudflare_dns_record" "grocy" {
  name    = "grocy.${local.cloudflare_domain}"
  zone_id = cloudflare_zone.domain.id
  content = loudflare_dns_record.ingress.name
  proxied = true
  type    = "CNAME"
  ttl     = 1
}

resource "cloudflare_dns_record" "hass" {
  name    = "hass.${local.cloudflare_domain}"
  zone_id = cloudflare_zone.domain.id
  content = loudflare_dns_record.ingress.name
  proxied = true
  type    = "CNAME"
  ttl     = 1
}

resource "cloudflare_dns_record" "l" {
  name    = "l.${local.cloudflare_domain}"
  zone_id = cloudflare_zone.domain.id
  content = loudflare_dns_record.ingress.name
  proxied = true
  type    = "CNAME"
  ttl     = 1
}

resource "cloudflare_dns_record" "oauth" {
  name    = "oauth.${local.cloudflare_domain}"
  zone_id = cloudflare_zone.domain.id
  content = loudflare_dns_record.ingress.name
  proxied = true
  type    = "CNAME"
  ttl     = 1
}

resource "cloudflare_dns_record" "doppler" {
  name    = local.doppler_domain
  zone_id = cloudflare_zone.domain.id
  content = local.doppler_value
  type    = "TXT"
  ttl     = 1
}

resource "cloudflare_dns_record" "chat" {
  name    = "chat.${local.cloudflare_domain}"
  zone_id = cloudflare_zone.domain.id
  content = loudflare_dns_record.ingress.name
  proxied = true
  type    = "CNAME"
  ttl     = 1
}
