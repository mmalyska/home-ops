variable "workspace_image" {
  description = "Full image reference for this workspace (Harbor path)"
  type        = string
}

variable "lb_ip" {
  description = "Fixed LoadBalancer IP from coder-pool for direct SSH (Hermes backend)"
  type        = string
}

variable "authorized_key" {
  description = "SSH public key installed in the workspace for Hermes direct SSH access"
  type        = string
  sensitive   = false
}

variable "storage_size" {
  description = "Home directory PVC size"
  type        = string
  default     = "20Gi"
}
