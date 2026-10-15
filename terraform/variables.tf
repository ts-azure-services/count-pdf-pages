variable "location" {
  type        = string
  description = "The Azure location in which the deployment is happening"
  default     = "westus"
}

variable "image_tag" {
  type        = string
  description = "Immutable tag for the pdf-tools image; supplied as TF_VAR_image_tag by the Makefile (a hash of the build inputs)"
}

variable "subscription_id" {
  type        = string
  description = "Subscription ID"
  default     = "<add subscription id>"
}

variable "tenant_id" {
  type        = string
  description = "Tenant ID"
  default     = "<add tenant ID>"
}

variable "generator_parallelism" {
  type        = number
  description = "Parallel replicas the PDF generator job runs; each makes NUM_DOCS / parallelism documents"
  default     = 50
}
