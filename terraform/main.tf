resource "random_pet" "main" {
  length = 2
}

locals {
  resource_suffix = random_pet.main.id
  tags = {
    Environment = "dev"
    Project     = "azure-search-demo"
    # Exempts resources from tenant security policies that force-disable
    # public network access on the storage account.
    # add any security policy exemptions
  }
  image = "${azurerm_container_registry.main.login_server}/pdf-tools:${var.image_tag}"
}

data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "main" {
  name     = "rg-${local.resource_suffix}"
  location = var.location
  tags     = local.tags
}

resource "azurerm_storage_account" "pdfstore" {
  name                      = "pdfstore${replace(local.resource_suffix, "-", "")}"
  resource_group_name       = azurerm_resource_group.main.name
  location                  = azurerm_resource_group.main.location
  account_tier              = "Standard"
  account_replication_type  = "LRS"
  shared_access_key_enabled = false
  tags                      = local.tags

  # Reachable from any network: IP allow lists don't apply to same-region Azure
  # services (the jobs), so access is controlled by Entra ID and RBAC instead
  # (shared keys are disabled).
  public_network_access_enabled = true
  network_rules {
    default_action = "Allow"
    bypass         = ["AzureServices"]
  }
}

resource "azurerm_role_assignment" "storage_blob_contributor" {
  scope                = azurerm_storage_account.pdfstore.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_storage_container" "pdfs" {
  name                  = "pdfs"
  storage_account_id    = azurerm_storage_account.pdfstore.id
  container_access_type = "private"

  depends_on = [azurerm_role_assignment.storage_blob_contributor]
}

resource "azurerm_storage_container" "results" {
  name                  = "results"
  storage_account_id    = azurerm_storage_account.pdfstore.id
  container_access_type = "private"

  depends_on = [azurerm_role_assignment.storage_blob_contributor]
}

resource "azurerm_container_registry" "main" {
  name                = "acr${replace(local.resource_suffix, "-", "")}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Basic"
  admin_enabled       = true
  tags                = local.tags
}

resource "azurerm_log_analytics_workspace" "main" {
  name                = "log-${local.resource_suffix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

resource "azurerm_container_app_environment" "main" {
  name                       = "cae-${local.resource_suffix}"
  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id
  tags                       = local.tags
}

# Build the shared jobs image in ACR; the tag is a hash of the build inputs.
resource "null_resource" "build_jobs_image" {
  triggers = {
    image_tag = var.image_tag
  }

  provisioner "local-exec" {
    command = <<EOT
      cd "${path.module}/.."
      az acr build \
        --registry ${azurerm_container_registry.main.name} \
        --image pdf-tools:${var.image_tag} \
        --platform linux/amd64 \
        --file jobs/Dockerfile \
        .
    EOT
  }

  depends_on = [azurerm_container_registry.main]
}

# Manually triggered job that writes generated PDFs straight into Blob Storage.
# The storage account and document count are supplied when the job is started
# (`make create-pdfs-azure`).
resource "azurerm_container_app_job" "pdf_generator" {
  name                         = "job-${local.resource_suffix}"
  resource_group_name          = azurerm_resource_group.main.name
  location                     = azurerm_resource_group.main.location
  container_app_environment_id = azurerm_container_app_environment.main.id
  replica_timeout_in_seconds   = 7200
  replica_retry_limit          = 0
  tags                         = local.tags

  manual_trigger_config {
    parallelism              = var.generator_parallelism
    replica_completion_count = var.generator_parallelism
  }

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
      name    = "generator"
      image   = local.image
      command = ["python", "create_pdfs.py"]
      cpu     = 1
      memory  = "2Gi"

      env {
        name  = "STORAGE_CONTAINER"
        value = azurerm_storage_container.pdfs.name
      }
    }
  }

  depends_on = [null_resource.build_jobs_image]
}

# Manually triggered job that analyzes one partition of the PDFs per execution.
# Container Apps gives replicas no index, so `make analyze-pdfs-azure` starts one
# execution per partition and passes PARTITION/PARTITIONS/RUN_ID as env vars.
resource "azurerm_container_app_job" "pdf_analyzer" {
  name                         = "analyze-${local.resource_suffix}"
  resource_group_name          = azurerm_resource_group.main.name
  location                     = azurerm_resource_group.main.location
  container_app_environment_id = azurerm_container_app_environment.main.id
  replica_timeout_in_seconds   = 7200
  replica_retry_limit          = 1
  tags                         = local.tags

  manual_trigger_config {
    parallelism              = 1
    replica_completion_count = 1
  }

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
      name    = "analyzer"
      image   = local.image
      command = ["python", "analyze_pdfs.py"]
      cpu     = 1
      memory  = "2Gi"

      env {
        name  = "STORAGE_CONTAINER"
        value = azurerm_storage_container.pdfs.name
      }
      env {
        name  = "RESULTS_CONTAINER"
        value = azurerm_storage_container.results.name
      }
    }
  }

  depends_on = [null_resource.build_jobs_image]
}

resource "azurerm_role_assignment" "generator_to_storage" {
  scope                = azurerm_storage_account.pdfstore.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_container_app_job.pdf_generator.identity[0].principal_id
}

resource "azurerm_role_assignment" "analyzer_to_storage" {
  scope                = azurerm_storage_account.pdfstore.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_container_app_job.pdf_analyzer.identity[0].principal_id
}
