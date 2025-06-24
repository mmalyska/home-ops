data "http" "uptimerobot_ips" {
  url = "https://uptimerobot.com/inc/files/ips/IPv4.txt"
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
  for_each = split("\r\n", chomp(data.http.uptimerobot_ips.response_body))
  ip = each.value
}
