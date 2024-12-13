resource "cloudflare_zero_trust_tunnel_cloudflared" "jaskinia" {
  account_id = cloudflare_account.main.id
  name       = "Jaskinia"
  secret     = local.cloudflare_tunnel_secret
  config_src = "cloudflare"
}

resource "doppler_secret" "cloudflare_tunnel" {
  provider = doppler.home-ops
  project = "home-ops"
  config  = "prd"
  name = "CLOUDFLARE_TUNNEL_TOKEN"
  value = cloudflare_zero_trust_tunnel_cloudflared.jaskinia.tunnel_token
}

resource "cloudflare_record" "ingress" {
  name    = "ingress"
  zone_id = data.cloudflare_zone.domain.id
  content   = "${cloudflare_zero_trust_tunnel_cloudflared.jaskinia.id}.cfargotunnel.com"
  proxied = true
  type    = "CNAME"
  ttl     = 1
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "jaskinia_config" {
  account_id = cloudflare_account.main.id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.jaskinia.id

  config {
    ingress_rule {
      hostname = "${local.cloudflare_domain}"
      service  = "https://traefik.traefik.svc.cluster.local:443"
      origin_request {
        origin_server_name = cloudflare_record.ingress.hostname
      }
    }
    ingress_rule {
      hostname = "*.${local.cloudflare_domain}"
      service  = "https://traefik.traefik.svc.cluster.local:443"
      origin_request {
        origin_server_name = cloudflare_record.ingress.hostname
      }
    }
    ingress_rule {
      service = "http_status:404"
    }
  }
}
