data "http" "uptimerobot_ips" {
  url = "https://uptimerobot.com/inc/files/ips/IPv4.txt"
}

resource "cloudflare_list" "uptimerobot" {
  account_id  = cloudflare_account.main.id
  name        = "uptimerobot"
  kind        = "ip"
  description = "List of UptimeRobot IP Addresses"

  dynamic "item" {
    for_each = split("\r\n", chomp(data.http.uptimerobot_ips.response_body))
    content {
      value {
        ip = item.value
      }
    }
  }
}

resource "cloudflare_ruleset" "zone_level_custom_waf" {
  zone_id     = data.cloudflare_zone.domain.id
  name        = "Custom WAF ruleset"
  description = "Zone-level WAF Custom Rules config"
  kind        = "zone"
  phase       = "http_request_firewall_custom"
  depends_on  = [
    cloudflare_list.uptimerobot,
  ]

  # Accept UptimeRobot Addresses
  rules {
    action      = "skip"
    expression  = "(ip.src in $uptimerobot)"
    description = "Expression to allow UptimeRobot IP addresses"
    enabled     = true
  }

  # Block Countries
  rules {
    action      = "block"
    expression  = "(ip.geoip.country in {\"CN\" \"IN\" \"RU\"})"
    description = "Expression to block countries"
    enabled     = true
  }

  # Block Bots
  rules {
    action      = "block"
    expression  = "(cf.client.bot) or (cf.threat_score gt 14)"
    description = "Expression to block bots determined by CF"
    enabled     = true
  }
}
