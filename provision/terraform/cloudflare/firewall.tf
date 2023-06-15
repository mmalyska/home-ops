# Block Countries
resource "cloudflare_ruleset" "block_countries" {
  zone_id     = data.cloudflare_zone.domain.id
  name        = "Firewall rule to block countries"
  description = "Firewall rule to block countries"
  kind        = "zone"
  phase       = "http_request_firewall_custom"

  rules {
    action      = "block"
    expression  = "(ip.geoip.country in {\"CN\" \"IN\" \"RU\"})"
    description = "Expression to block countries"
    enabled     = true
  }
}

# Block Bots
resource "cloudflare_ruleset" "block_bots" {
  zone_id     = data.cloudflare_zone.domain.id
  name        = "Firewall rule to block bots determined by CF"
  description = "Firewall rule to block bots determined by CF"
  kind        = "zone"
  phase       = "http_request_firewall_custom"

  rules {
    action      = "block"
    expression  = "(cf.client.bot) or (cf.threat_score gt 14)"
    description = "Expression to block bots determined by CF"
    enabled     = true
  }
}

# Accept UptimeRobot Addresses
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

resource "cloudflare_ruleset" "uptimerobot" {
  zone_id     = data.cloudflare_zone.domain.id
  name        = "Firewall rule to allow UptimeRobot IP addresses"
  description = "Firewall rule to allow UptimeRobot IP addresses"
  kind        = "zone"
  phase       = "http_request_firewall_custom"
  depends_on  = [
      cloudflare_list.uptimerobot,
    ]

  rules {
    action      = "allow"
    expression  = "(ip.src in $uptimerobot)"
    description = "Expression to allow UptimeRobot IP addresses"
    enabled     = true
  }
}
