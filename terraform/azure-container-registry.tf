resource "azurerm_container_registry" "container_registry" {
  name                          = var.project
  resource_group_name = azurerm_resource_group.azure_resource_group.name
  location = azurerm_resource_group.azure_resource_group.location
  sku                           = "Premium"
  admin_enabled                 = false
  public_network_access_enabled = true
  anonymous_pull_enabled        = false
}