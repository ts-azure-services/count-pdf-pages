variable "location" {
  type        = string
  description = "The Azure location in which the deployment is happening"
  default     = "westus"
}

variable "local_pdf_path" {
  type        = string
  description = "Path to local PDF folder"
  default     = "./../pdfs"
}

variable "subscription_id" {
  type        = string
  description = "Subscription ID"
  default     = "<enter your subscription id>"
}

variable "tenant_id" {
  type        = string
  description = "Tenant ID"
  default     = "<enter your tenant id>"
}
