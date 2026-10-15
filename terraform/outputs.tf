output "container_registry_name" {
  description = "Name of the Azure Container Registry used for remote image builds"
  value       = azurerm_container_registry.main.name
}

output "resource_group_name" {
  description = "Name of the resource group"
  value       = azurerm_resource_group.main.name
}

output "storage_account_name" {
  description = "Name of the storage account"
  value       = azurerm_storage_account.pdfstore.name
}

output "storage_container_name" {
  description = "Name of the storage container for PDFs"
  value       = azurerm_storage_container.pdfs.name
}

output "results_container_name" {
  description = "Name of the storage container for analysis Parquet files"
  value       = azurerm_storage_container.results.name
}

output "pdf_generator_job_name" {
  description = "Container Apps Job that generates PDFs directly into Blob Storage"
  value       = azurerm_container_app_job.pdf_generator.name
}

output "pdf_analyzer_job_name" {
  description = "Container Apps Job that extracts PDF attributes into Parquet"
  value       = azurerm_container_app_job.pdf_analyzer.name
}
