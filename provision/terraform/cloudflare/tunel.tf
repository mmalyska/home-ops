resource "cloudflare_zero_trust_tunnel_cloudflared" "jaskinia" {
  account_id = cloudflare_account.main.id
  name       = "Jaskinia"
  tunnel_secret     = local.cloudflare_tunnel_secret
  config_src = "cloudflare"
}

data "cloudflare_zero_trust_tunnel_cloudflared_token" "jaskinia" {
  account_id = cloudflare_account.main.id
  tunnel_id = cloudflare_zero_trust_tunnel_cloudflared.jaskinia.id
}

resource "doppler_secret" "cloudflare_tunnel" {
  provider = doppler.home-ops
  project = "home-ops"
  config  = "prd"
  name = "CLOUDFLARE_TUNNEL_TOKEN"
  value = data.cloudflare_zero_trust_tunnel_cloudflared_token.jaskinia.token
}

resource "cloudflare_dns_record" "ingress" {
  name    = "ingress"
  zone_id = cloudflare_zone.domain.id
  content   = "${cloudflare_zero_trust_tunnel_cloudflared.jaskinia.id}.cfargotunnel.com"
  proxied = true
  type    = "CNAME"
  ttl     = 1
}

locals {
  cloudflare_ingress_hostname = "${cloudflare_dns_record.ingress.name}.${local.cloudflare_domain}"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "jaskinia_config" {
  account_id = cloudflare_account.main.id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.jaskinia.id

  config = {
    ingress = [{
      hostname = "${local.cloudflare_domain}"
      service  = "https://traefik.traefik.svc.cluster.local:443"
      origin_request = {
        origin_server_name = local.cloudflare_ingress_hostname
      }
    },
    {
      hostname = "*.${local.cloudflare_domain}"
      service  = "https://traefik.traefik.svc.cluster.local:443"
      origin_request = {
        origin_server_name = local.cloudflare_ingress_hostname
      }
    },
    {
      service = "http_status:404"
    }]
  }
}
