terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=3.0.0"
    }
  }
}

provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "func-rg" {
  name     = "Task-Function"
  location = "eastus2"
}

resource "azurerm_resource_group" "back-rg" {
  name     = "Task-Backend"
  location = "eastus"
}

resource "azurerm_resource_group" "front-rg" {
  name     = "Task-Frontend"
  location = "Central India"
}

# FrontEnd
# Storage Account

resource "azurerm_storage_account" "front-stg" {
  name                     = "functiontaskstg"
  resource_group_name      = azurerm_resource_group.front-rg.name
  location                 = azurerm_resource_group.front-rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

# $web Container
resource "azurerm_storage_container" "web-stg" {
  name                  = "$web"
  storage_account_name  = azurerm_storage_account.front-stg.name
  container_access_type = "private"
}

# CDN Profile
resource "azurerm_cdn_profile" "front-cdnp" {
  name                = "frontend-cdn-profile"
  location            = azurerm_resource_group.front-rg.location
  resource_group_name = azurerm_resource_group.front-rg.name
  sku                 = "Standard_Verizon"
}


# CDN endpoint
resource "azurerm_cdn_endpoint" "front-cdn" {
  name                = "front-endpoint"
  profile_name        = azurerm_cdn_profile.front-cdnp.name
  location            = azurerm_resource_group.front-rg.location
  resource_group_name = azurerm_resource_group.front-rg.name

  origin {
    name      = "taskfrontendcdn"
    host_name = azurerm_storage_account.front-stg.primary_web_host
  }
}


# Virtual Network
resource "azurerm_virtual_network" "task-vnet" {
  name                = "Task-Vnet"
  location            = azurerm_resource_group.back-rg.location
  resource_group_name = azurerm_resource_group.back-rg.name
  address_space       = ["10.0.0.0/16"]

}

# Subnet
resource "azurerm_subnet" "as-subnet" {
  name                 = "as_sub"
  resource_group_name  = azurerm_resource_group.back-rg.name
  virtual_network_name = azurerm_virtual_network.task-vnet.name
  address_prefixes     = ["10.0.0.0/24"]
  delegation {
    name = "delegation"
  
    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "db-subnet" {
  name                 = "db_sub"
  resource_group_name  = azurerm_resource_group.back-rg.name
  virtual_network_name = azurerm_virtual_network.task-vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# Azure Service Plan For Backend
resource "azurerm_service_plan" "back-sp" {
  name                = "taskbackendasp"
  resource_group_name = azurerm_resource_group.back-rg.name
  location            = azurerm_resource_group.back-rg.location
  os_type             = "Linux"
  sku_name            = "B1"
}

resource "azurerm_linux_web_app" "back-as" {
  name                = "task-appservice"
  resource_group_name = azurerm_resource_group.back-rg.name
  location            = azurerm_resource_group.back-rg.location
  service_plan_id     = azurerm_service_plan.back-sp.id

  site_config {
    vnet_route_all_enabled = true
  }
}

# Vnet Integration for app service
resource "azurerm_app_service_virtual_network_swift_connection" "as-vnet" {
  app_service_id = azurerm_linux_web_app.back-as.id
  subnet_id      = azurerm_subnet.as-subnet.id 
  depends_on = [ azurerm_subnet.as-subnet ]
}

## DATABASE
resource "azurerm_cosmosdb_account" "dbacc" {
  name                = "task-backend-db-simform"
  location            = azurerm_resource_group.back-rg.location
  resource_group_name = azurerm_resource_group.back-rg.name
  offer_type          = "Standard"
  kind                = "MongoDB"

  enable_automatic_failover         = false
  is_virtual_network_filter_enabled = true
  public_network_access_enabled = false

  // set ip_range_filter to allow azure services (0.0.0.0) and azure portal.
  // https://docs.microsoft.com/en-us/azure/cosmos-db/how-to-configure-firewall#allow-requests-from-the-azure-portal
  // https://docs.microsoft.com/en-us/azure/cosmos-db/how-to-configure-firewall#allow-requests-from-global-azure-datacenters-or-other-sources-within-azure
  ip_range_filter = "0.0.0.0,104.42.195.92,40.76.54.131,52.176.6.30,52.169.50.45,52.187.184.26"

  capabilities {
    name = "EnableMongo"

  }

  consistency_policy {
    consistency_level       = "BoundedStaleness"
    max_interval_in_seconds = 310
    max_staleness_prefix    = 101000
  }

  geo_location {
    location          = azurerm_resource_group.back-rg.location
    failover_priority = 0
  }
}

# NIC
resource "azurerm_network_interface" "db-nic" {
  name                = "taskdbnic"
  location            = azurerm_resource_group.back-rg.location
  resource_group_name = azurerm_resource_group.back-rg.name

  ip_configuration {
    name                          = "dbnic"
    subnet_id                     = azurerm_subnet.db-subnet.id
    private_ip_address_allocation = "Dynamic"
  }
}


# EndPoint
resource "azurerm_private_endpoint" "pvt-endpoint" {
  name                = "Mongo-private-endpoint"
  location            = azurerm_resource_group.back-rg.location
  resource_group_name = azurerm_resource_group.back-rg.name
  subnet_id           = azurerm_subnet.db-subnet.id

  private_service_connection {
    name                           = "tfex-cosmosdb-connection"
    is_manual_connection       = true
    private_connection_resource_id = azurerm_cosmosdb_account.dbacc.id
    subresource_names              = ["MongoDB"]
    request_message            = "-"
  }
  depends_on = [ azurerm_network_interface.db-nic ]
}

# Function
# Azure Service Plan For Function

resource "azurerm_service_plan" "func-sp" {
  name                = "taskfunctionasp"
  resource_group_name = azurerm_resource_group.func-rg.name
  location            = azurerm_resource_group.func-rg.location
  os_type             = "Linux"
  sku_name            = "B1"
}

resource "azurerm_storage_account" "func-stg" {
  name                     = "functiontaskfunctionstg"
  resource_group_name      = azurerm_resource_group.func-rg.name
  location                 = azurerm_resource_group.func-rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  depends_on = [azurerm_resource_group.func-rg]
}

# Azure Function 

resource "azurerm_linux_function_app" "function_app" {
  name                = "task-function-python-app"
  resource_group_name = azurerm_resource_group.func-rg.name
  location            = azurerm_resource_group.func-rg.location
  service_plan_id     = azurerm_service_plan.func-sp.id
  #service_plan_id           = azurerm_app_service_plan.func-sp.id
  storage_account_name       = azurerm_storage_account.func-stg.name
  storage_account_access_key = azurerm_storage_account.func-stg.primary_access_key
  https_only                 = true

  site_config {
    minimum_tls_version = "1.2"
  }
  depends_on = [azurerm_service_plan.func-sp]
}
