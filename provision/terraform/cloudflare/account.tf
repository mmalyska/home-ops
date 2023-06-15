resource "cloudflare_account" "main" {
  name              = "main"
  type              = "standard"
  enforce_twofactor = true
}
