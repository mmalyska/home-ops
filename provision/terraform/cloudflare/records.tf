resource "cloudflare_record" "dynhost" {
  name    = "dynhost"
  zone_id = lookup(data.cloudflare_zones.domain.zones[0], "id")
  value   = chomp(data.http.ipv4.response_body) # will by updated dynamically by dyndns
  proxied = true
  type    = "A"
  ttl     = 1
}

resource "cloudflare_record" "root" {
  name    = data.sops_file.cloudflare_secrets.data["cloudflare_domain"]
  zone_id = lookup(data.cloudflare_zones.domain.zones[0], "id")
  value   = "dynhost.${data.sops_file.cloudflare_secrets.data["cloudflare_domain"]}"
  proxied = true
  type    = "CNAME"
  ttl     = 1
}

resource "cloudflare_record" "grocy" {
  name    = "grocy"
  zone_id = lookup(data.cloudflare_zones.domain.zones[0], "id")
  value   = "dynhost.${data.sops_file.cloudflare_secrets.data["cloudflare_domain"]}"
  proxied = true
  type    = "CNAME"
  ttl     = 1
}

resource "cloudflare_record" "hass" {
  name    = "hass"
  zone_id = lookup(data.cloudflare_zones.domain.zones[0], "id")
  value   = "dynhost.${data.sops_file.cloudflare_secrets.data["cloudflare_domain"]}"
  proxied = true
  type    = "CNAME"
  ttl     = 1
}

resource "cloudflare_record" "l" {
  name    = "l"
  zone_id = lookup(data.cloudflare_zones.domain.zones[0], "id")
  value   = "dynhost.${data.sops_file.cloudflare_secrets.data["cloudflare_domain"]}"
  proxied = true
  type    = "CNAME"
  ttl     = 1
}

resource "cloudflare_record" "oauth" {
  name    = "oauth"
  zone_id = lookup(data.cloudflare_zones.domain.zones[0], "id")
  value   = "dynhost.${data.sops_file.cloudflare_secrets.data["cloudflare_domain"]}"
  proxied = true
  type    = "CNAME"
  ttl     = 1
}

resource "cloudflare_record" "doppler" {
  name    = "${data.sops_file.cloudflare_secrets.data["doppler_domain"]}"
  zone_id = lookup(data.cloudflare_zones.domain.zones[0], "id")
  value   = "${data.sops_file.cloudflare_secrets.data["doppler_value"]}"
  type    = "TXT"
  ttl     = 1
}
