resource "cloudflare_record" "dynhost" {
  name    = "dynhost"
  zone_id = lookup(data.cloudflare_zones.domain.zones[0], "id")
  proxied = true
  type    = "A"
  ttl     = 1
}

resource "cloudflare_record" "root" {
  name    = local.cloudflare_domain
  zone_id = lookup(data.cloudflare_zones.domain.zones[0], "id")
  value   = "dynhost.${local.cloudflare_domain}"
  proxied = true
  type    = "CNAME"
  ttl     = 1
}

resource "cloudflare_record" "grocy" {
  name    = "grocy"
  zone_id = lookup(data.cloudflare_zones.domain.zones[0], "id")
  value   = "dynhost.${local.cloudflare_domain}"
  proxied = true
  type    = "CNAME"
  ttl     = 1
}

resource "cloudflare_record" "hass" {
  name    = "hass"
  zone_id = lookup(data.cloudflare_zones.domain.zones[0], "id")
  value   = "dynhost.${local.cloudflare_domain}"
  proxied = true
  type    = "CNAME"
  ttl     = 1
}

resource "cloudflare_record" "l" {
  name    = "l"
  zone_id = lookup(data.cloudflare_zones.domain.zones[0], "id")
  value   = "dynhost.${local.cloudflare_domain}"
  proxied = true
  type    = "CNAME"
  ttl     = 1
}

resource "cloudflare_record" "oauth" {
  name    = "oauth"
  zone_id = lookup(data.cloudflare_zones.domain.zones[0], "id")
  value   = "dynhost.${local.cloudflare_domain}"
  proxied = true
  type    = "CNAME"
  ttl     = 1
}

resource "cloudflare_record" "doppler" {
  name    = "${local.doppler_domain}"
  zone_id = lookup(data.cloudflare_zones.domain.zones[0], "id")
  value   = "${local.doppler_value}"
  type    = "TXT"
  ttl     = 1
}
