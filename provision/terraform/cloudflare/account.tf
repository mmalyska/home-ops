resource "cloudflare_account" "main" {
  name              = "main"
  settings = {
      enforce_twofactor = true
  }
}
