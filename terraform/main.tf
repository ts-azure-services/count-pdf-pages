resource "random_pet" "main" {
  length = 2
}

locals {
  resource_suffix = random_pet.main.id
  tags = {
    Environment = "dev"
    Project     = "azure-search-demo"
  }
}

data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "main" {
  name     = "rg-${local.resource_suffix}"
  location = var.location
  tags     = local.tags
}

resource "azurerm_storage_account" "pdfstore" {
  name                    = "pdfstore${replace(local.resource_suffix, "-", "")}"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  shared_access_key_enabled = false
  tags                     = local.tags
}

resource "azurerm_role_assignment" "storage_blob_contributor" {
  scope                = azurerm_storage_account.pdfstore.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_storage_container" "pdfs" {
  name                  = "pdfs"
  storage_account_id  = azurerm_storage_account.pdfstore.id
  container_access_type = "private"

  # Ensure role assignment is created first
  depends_on = [azurerm_role_assignment.storage_blob_contributor]
}

resource "azurerm_search_service" "main" {
  name                = "searchsvc-${replace(local.resource_suffix, "-", "")}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "basic"
  replica_count       = 1
  partition_count     = 1
  tags                = local.tags

  identity {
    type = "SystemAssigned"
  }
}

# Grant the search service access to the storage account
resource "azurerm_role_assignment" "search_to_storage" {
  scope                = azurerm_storage_account.pdfstore.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_search_service.main.identity[0].principal_id
  # principal_id         = azurerm_search_service.main.object_id

  depends_on = [azurerm_search_service.main]
}


# Container Registry
resource "azurerm_container_registry" "main" {
  name                = "acr${replace(local.resource_suffix, "-", "")}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Basic"
  admin_enabled       = true
  tags                = local.tags
}

# Log Analytics Workspace for Container Apps
resource "azurerm_log_analytics_workspace" "main" {
  name                = "log-${local.resource_suffix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

# Container Apps Environment
resource "azurerm_container_app_environment" "main" {
  name                       = "cae-${local.resource_suffix}"
  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id
  tags                       = local.tags
}

# Build and push Docker image using ACR
resource "null_resource" "build_and_push_image" {
  triggers = {
    dockerfile_hash = filemd5("${path.module}/../container_app/Dockerfile")
    app_hash        = filemd5("${path.module}/../container_app/app.py")
  }

  provisioner "local-exec" {
    command = <<EOT
      cd ${path.module}/../container_app
      
      # Build in Azure (handles platform automatically)
      az acr build \
        --registry ${azurerm_container_registry.main.name} \
        --image page-counter:latest \
        --platform linux/amd64 \
        .
    EOT
  }

  depends_on = [azurerm_container_registry.main]
}

# Container App
resource "azurerm_container_app" "page_counter" {
  name                         = "ca-${local.resource_suffix}"
  resource_group_name          = azurerm_resource_group.main.name
  container_app_environment_id = azurerm_container_app_environment.main.id
  revision_mode                = "Single"
  tags                         = local.tags

  identity {
    type = "SystemAssigned"
  }

  registry {
    server               = azurerm_container_registry.main.login_server
    username             = azurerm_container_registry.main.admin_username
    password_secret_name = "acr-password"
  }

  secret {
    name  = "acr-password"
    value = azurerm_container_registry.main.admin_password
  }

  template {
    container {
      name   = "page-counter"
      image  = "${azurerm_container_registry.main.login_server}/page-counter:latest"
      cpu    = 0.5
      memory = "1Gi"

    }

    min_replicas = 0
    max_replicas = 10

    http_scale_rule {
      name                = "http-scaling"
      concurrent_requests = 10
    }
  }

  ingress {
    external_enabled = true
    target_port      = 8080
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  depends_on = [
    null_resource.build_and_push_image
  ]

  lifecycle {
    replace_triggered_by = [
      null_resource.build_and_push_image  # Recreate if image changes
    ]
  }
}

# Grant Container App access to read PDFs from blob storage
resource "azurerm_role_assignment" "containerapp_to_storage" {
  scope                = azurerm_storage_account.pdfstore.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_container_app.page_counter.identity[0].principal_id
}

# variable "local_pdf_path" {
#   type        = string
#   description = "Path to local PDF folder"
#   default     = "./pdfs"
# }
#
# resource "null_resource" "upload_pdfs" {
#   provisioner "local-exec" {
#     command = <<EOT
#       az storage blob upload-batch \
#         --account-name ${azurerm_storage_account.pdfstore.name} \
#         --destination ${azurerm_storage_container.pdfs.name} \
#         --source ${var.local_pdf_path}
#     EOT
#   }
#
#   depends_on = [
#     azurerm_storage_container.pdfs
#   ]
# }

# Create data source via REST API
resource "null_resource" "search_datasource" {
  triggers = {
    search_service  = azurerm_search_service.main.id
    storage_account = azurerm_storage_account.pdfstore.id
  }

  provisioner "local-exec" {
    command = <<EOT
      curl -X PUT "https://${azurerm_search_service.main.name}.search.windows.net/datasources/pdf-datasource?api-version=2024-07-01" \
        -H "Content-Type: application/json" \
        -H "api-key: ${azurerm_search_service.main.primary_key}" \
        -d '{
          "name": "pdf-datasource",
          "type": "azureblob",
          "credentials": {
            "connectionString": "ResourceId=${azurerm_storage_account.pdfstore.id};"
          },
          "container": {
            "name": "${azurerm_storage_container.pdfs.name}"
          },
          "description": "PDF Blob Data Source"
        }'
    EOT
  }

  depends_on = [
    azurerm_search_service.main,
    azurerm_storage_container.pdfs,
    azurerm_role_assignment.search_to_storage
  ]
}

# Create index via REST API
resource "null_resource" "search_index" {
  triggers = {
    search_service = azurerm_search_service.main.id
  }

  provisioner "local-exec" {
    command = <<EOT
      curl -X PUT "https://${azurerm_search_service.main.name}.search.windows.net/indexes/pdf-pagecount-index?api-version=2024-07-01" \
        -H "Content-Type: application/json" \
        -H "api-key: ${azurerm_search_service.main.primary_key}" \
        -d '{
          "name": "pdf-pagecount-index",
          "fields": [
            {
              "name": "id",
              "type": "Edm.String",
              "key": true,
              "searchable": false
            },
            {
              "name": "file_name",
              "type": "Edm.String",
              "searchable": false,
              "filterable": true,
              "sortable": true
            },
            {
              "name": "file_path",
              "type": "Edm.String",
              "searchable": false,
              "filterable": true
            },
            {
              "name": "page_count",
              "type": "Edm.Int32",
              "filterable": true,
              "sortable": true
            }
          ]
        }'
    EOT
  }

  depends_on = [azurerm_search_service.main]
}


resource "null_resource" "search_skillset" {
  triggers = {
    search_service  = azurerm_search_service.main.id
    container_app   = azurerm_container_app.page_counter.id
  }
  
  provisioner "local-exec" {
    command = <<EOT
      curl -X PUT "https://${azurerm_search_service.main.name}.search.windows.net/skillsets/pdf-extraction-skillset?api-version=2024-07-01" \
        -H "Content-Type: application/json" \
        -H "api-key: ${azurerm_search_service.main.primary_key}" \
        -d '{
          "name": "pdf-extraction-skillset",
          "description": "Extract page count from PDFs using Container App",
          "skills": [
            {
              "@odata.type": "#Microsoft.Skills.Custom.WebApiSkill",
              "name": "page-counter",
              "description": "Counts pages in PDF using PyPDF2 in Container App",
              "context": "/document",
              "uri": "https://${azurerm_container_app.page_counter.ingress[0].fqdn}/api/PageCounter",
              "httpMethod": "POST",
              "timeout": "PT90S",
              "batchSize": 1,
              "degreeOfParallelism": 5,
              "inputs": [
                {
                  "name": "metadata_storage_path",
                  "source": "/document/metadata_storage_path"
                }
              ],
              "outputs": [
                {
                  "name": "page_count",
                  "targetName": "pageCount"
                }
              ]
            }
          ]
        }'
    EOT
  }
  
  depends_on = [
    azurerm_search_service.main,
    azurerm_container_app.page_counter,
    azurerm_role_assignment.containerapp_to_storage
  ]
}


resource "null_resource" "search_indexer" {
  triggers = {
    datasource = null_resource.search_datasource.id
    index      = null_resource.search_index.id
    skillset   = null_resource.search_skillset.id
  }

  provisioner "local-exec" {
    command = <<EOT
      curl -X PUT "https://${azurerm_search_service.main.name}.search.windows.net/indexers/pdf-pagecount-indexer?api-version=2024-07-01" \
        -H "Content-Type: application/json" \
        -H "api-key: ${azurerm_search_service.main.primary_key}" \
        -d '{
          "name": "pdf-pagecount-indexer",
          "dataSourceName": "pdf-datasource",
          "targetIndexName": "pdf-pagecount-index",
          "skillsetName": "pdf-extraction-skillset",
          "fieldMappings": [
            {
              "sourceFieldName": "metadata_storage_name",
              "targetFieldName": "file_name"
            },
            {
              "sourceFieldName": "metadata_storage_path",
              "targetFieldName": "file_path"
            }
          ],
          "outputFieldMappings": [
            {
              "sourceFieldName": "/document/pageCount",
              "targetFieldName": "page_count"
            }
          ],
          "parameters": {
            "configuration": {
              "dataToExtract": "contentAndMetadata",
              "imageAction": "none"
            }
          }
        }'
    EOT
  }

  depends_on = [
    null_resource.search_datasource,
    null_resource.search_index,
    null_resource.search_skillset
  ]
}
