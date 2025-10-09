output "container_app_url" {
  description = "URL of the Container App page counter API"
  value       = "https://${azurerm_container_app.page_counter.ingress[0].fqdn}/api/PageCounter"
}

output "search_service_endpoint" {
  description = "Azure Search service endpoint URL"
  value       = "https://${azurerm_search_service.main.name}.search.windows.net"
}

output "search_service_key" {
  description = "Azure Search service primary admin key"
  value       = azurerm_search_service.main.primary_key
  sensitive   = true
}

output "search_service_index" {
  description = "Name of the Azure Search index"
  value       = "pdf-pagecount-index"
}

output "search_service_name" {
  description = "Name of the Azure Search service"
  value       = azurerm_search_service.main.name
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
