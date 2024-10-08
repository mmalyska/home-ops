data "cloudflare_zone" "domain" {
  name = local.cloudflare_domain
}

resource "cloudflare_zone_settings_override" "cloudflare_settings" {
  zone_id = data.cloudflare_zone.domain.id
  settings {
    # /ssl-tls
    always_use_https         = "on"
    ssl                      = "strict"
    # /ssl-tls/edge-certificates
    min_tls_version          = "1.2"
    opportunistic_encryption = "on"
    tls_1_3                  = "zrt"
    automatic_https_rewrites = "on"
    universal_ssl            = "on"
    # /firewall/settings
    browser_check  = "on"
    challenge_ttl  = 1800
    privacy_pass   = "on"
    security_level = "medium"
    # /speed/optimization
    brotli = "on"
    rocket_loader = "on"
    # /caching/configuration
    always_online    = "off"
    development_mode = "off"
    # /network
    http3               = "on"
    zero_rtt            = "on"
    ipv6                = "on"
    websockets          = "on"
    opportunistic_onion = "on"
    pseudo_ipv4         = "off"
    ip_geolocation      = "on"
    # /content-protection
    email_obfuscation   = "on"
    server_side_exclude = "on"
    hotlink_protection  = "on"
    # /workers
    security_header {
      enabled = false
    }
  }
}
