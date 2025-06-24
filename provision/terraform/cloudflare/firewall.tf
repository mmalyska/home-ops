data "http" "uptimerobot_ips" {
  url = "https://uptimerobot.com/inc/files/ips/IPv4.txt"
}

locals {
  uptime_ips = split("\r\n", data.http.uptimerobot_ips.response_body)
}

resource "cloudflare_list" "uptimerobot" {
  account_id  = cloudflare_account.main.id
  name        = "uptimerobot"
  kind        = "ip"
  description = "List of UptimeRobot IP Addresses"
}

resource "cloudflare_list_item" "example" {
  account_id = cloudflare_account.main.id
  list_id = cloudflare_list.uptimerobot.id
  for_each = toset(local.uptime_ips)
  ip = each.value
}

resource "cloudflare_ruleset" "zone_level_custom_waf" {
  zone_id     = cloudflare_zone.domain.id
  name        = "Custom WAF ruleset"
  description = "Zone-level WAF Custom Rules config"
  kind        = "zone"
  phase       = "http_request_firewall_custom"
  depends_on  = [
    cloudflare_list.uptimerobot,
  ]

  # Accept UptimeRobot Addresses
  rules = [{
    action      = "skip"
    action_parameters = {
      ruleset = "current"
    }
    expression  = "(ip.src in $uptimerobot)"
    description = "Expression to allow UptimeRobot IP addresses"
    enabled     = true
    logging = {
      enabled   = true
    }
  },
  # Block Countries
  {
    action      = "block"
    expression  = "(ip.geoip.country in {\"CN\" \"IN\" \"RU\"})"
    description = "Expression to block countries"
    enabled     = true
  },
  # Block Bots
  {
    action      = "block"
    expression  = "(cf.client.bot) or (cf.threat_score gt 14)"
    description = "Expression to block bots determined by CF"
    enabled     = true
  }]
}
