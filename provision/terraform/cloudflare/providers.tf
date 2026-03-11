provider "cloudflare" {
  email   = local.cloudflare_email
  api_key = local.cloudflare_apikey
}

provider "bitwarden-secrets" {
  access_token    = var.bw_access_token
  organization_id = var.bw_organization_id
}
