variable "location" {
  type        = string
  description = "The Azure location in which the deployment is happening"
  default     = "westus"
}

variable "subscription_id" {
  type        = string
  description = "Subscription ID"
  default     = "7d80067a-1c52-4511-bf6b-af8bfeda49db"
}

variable "tenant_id" {
  type        = string
  description = "Tenant ID"
  default     = "16b3c013-d300-468d-ac64-7eda0820b6d3"
}
