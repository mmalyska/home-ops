data "bitwarden-secrets_secret" "cloudflare_email" {
  id = "22151db9-baf0-4e07-ae88-b40a00d7a9f8"
}

data "bitwarden-secrets_secret" "cloudflare_apikey" {
  id = "b89913d7-ff43-4504-9844-b40a00d7eb52"
}

data "bitwarden-secrets_secret" "cloudflare_domain" {
  id = "3080c3a1-7d8e-431f-9538-b40a00d82117"
}

locals {
  cloudflare_email  = data.bitwarden-secrets_secret.cloudflare_email.value
  cloudflare_apikey = data.bitwarden-secrets_secret.cloudflare_apikey.value
  cloudflare_domain = data.bitwarden-secrets_secret.cloudflare_domain.value
}
