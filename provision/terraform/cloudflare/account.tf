resource "cloudflare_account" "main" {
  name              = "main"
  type              = "standard"
  settings = {
      enforce_twofactor = true
    }
}
