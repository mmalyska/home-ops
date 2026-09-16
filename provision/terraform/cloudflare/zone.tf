resource "cloudflare_zone" "domain" {
  account = {
    id = cloudflare_account.main.id
  }
  name = local.cloudflare_domain
}

resource "cloudflare_zone_setting" "zone_setting_always_use_https" {
  zone_id = cloudflare_zone.domain.id
  setting_id = "always_use_https"
  value = "on"
}

resource "cloudflare_zone_setting" "zone_setting_ssl" {
  zone_id = cloudflare_zone.domain.id
  setting_id = "ssl"
  value = "strict"
}

resource "cloudflare_zone_setting" "zone_setting_min_tls_version" {
  zone_id = cloudflare_zone.domain.id
  setting_id = "min_tls_version"
  value = "1.2"
}

resource "cloudflare_zone_setting" "zone_setting_opportunistic_encryption" {
  zone_id = cloudflare_zone.domain.id
  setting_id = "opportunistic_encryption"
  value = "on"
}

resource "cloudflare_zone_setting" "zone_setting_tls_1_3" {
  zone_id = cloudflare_zone.domain.id
  setting_id = "tls_1_3"
  value = "zrt"
}

resource "cloudflare_zone_setting" "zone_setting_automatic_https_rewrites" {
  zone_id = cloudflare_zone.domain.id
  setting_id = "automatic_https_rewrites"
  value = "on"
}

resource "cloudflare_zone_setting" "zone_setting_browser_check" {
  zone_id = cloudflare_zone.domain.id
  setting_id = "browser_check"
  value = "on"
}

resource "cloudflare_zone_setting" "zone_setting_challenge_ttl" {
  zone_id = cloudflare_zone.domain.id
  setting_id = "challenge_ttl"
  value = 1800
}

resource "cloudflare_zone_setting" "zone_setting_privacy_pass" {
  zone_id = cloudflare_zone.domain.id
  setting_id = "privacy_pass"
  value = "on"
}

resource "cloudflare_zone_setting" "zone_setting_security_level" {
  zone_id = cloudflare_zone.domain.id
  setting_id = "security_level"
  value = "medium"
}

resource "cloudflare_zone_setting" "zone_setting_brotli" {
  zone_id = cloudflare_zone.domain.id
  setting_id = "brotli"
  value = "on"
}

resource "cloudflare_zone_setting" "zone_setting_rocket_loader" {
  zone_id = cloudflare_zone.domain.id
  setting_id = "rocket_loader"
  value = "on"
}

# Rocket Loader rewrites <script> tags in a way that only its own loader
# script can execute -- but that loader script isn't nonce'd, so it's
# blocked outright by CSPs using 'strict-dynamic' (e.g. Nextcloud's login
# page), which silently breaks all JS on the page. Disable it per-host
# for apps that ship a strict-dynamic CSP, instead of weakening their CSP
# or disabling Rocket Loader zone-wide.
resource "cloudflare_ruleset" "zone_level_config_rules" {
  zone_id     = cloudflare_zone.domain.id
  name        = "Configuration Rules"
  description = "Per-host overrides of zone-level settings"
  kind        = "zone"
  phase       = "http_config_settings"

  rules = [
    {
      action = "set_config"
      action_parameters = {
        rocket_loader = false
      }
      expression  = "(http.host eq \"nextcloud.${local.cloudflare_domain}\")"
      description = "Disable Rocket Loader for Nextcloud (breaks strict-dynamic CSP login page)"
      enabled     = true
    }
  ]
}

resource "cloudflare_zone_setting" "zone_setting_always_online" {
  zone_id = cloudflare_zone.domain.id
  setting_id = "always_online"
  value = "off"
}

resource "cloudflare_zone_setting" "zone_setting_development_mode" {
  zone_id = cloudflare_zone.domain.id
  setting_id = "development_mode"
  value = "off"
}

resource "cloudflare_zone_setting" "zone_setting_http3" {
  zone_id = cloudflare_zone.domain.id
  setting_id = "http3"
  value = "on"
}

resource "cloudflare_zone_setting" "zone_setting_opportunistic_onion" {
  zone_id = cloudflare_zone.domain.id
  setting_id = "opportunistic_onion"
  value = "on"
}

resource "cloudflare_zone_setting" "zone_setting_ipv6" {
  zone_id = cloudflare_zone.domain.id
  setting_id = "ipv6"
  value = "on"
}

resource "cloudflare_zone_setting" "zone_setting_websockets" {
  zone_id = cloudflare_zone.domain.id
  setting_id = "websockets"
  value = "on"
}

resource "cloudflare_zone_setting" "zone_setting_pseudo_ipv4" {
  zone_id = cloudflare_zone.domain.id
  setting_id = "pseudo_ipv4"
  value = "off"
}

resource "cloudflare_zone_setting" "zone_setting_ip_geolocation" {
  zone_id = cloudflare_zone.domain.id
  setting_id = "ip_geolocation"
  value = "on"
}

resource "cloudflare_zone_setting" "zone_setting_email_obfuscation" {
  zone_id = cloudflare_zone.domain.id
  setting_id = "email_obfuscation"
  value = "on"
}

resource "cloudflare_zone_setting" "zone_setting_server_side_exclude" {
  zone_id = cloudflare_zone.domain.id
  setting_id = "server_side_exclude"
  value = "on"
}

resource "cloudflare_zone_setting" "zone_setting_hotlink_protection" {
  zone_id = cloudflare_zone.domain.id
  setting_id = "hotlink_protection"
  value = "on"
}
