provider "azurerm" {
  # Whilst version is optional, we /strongly recommend/ using it to pin the version of the Provider being used
  version=">=2.16"
  features {}

}

resource "azurerm_resource_group" "aks_rg" {
  name     = "${var.prefix}-rg"
  location = "${var.location}"
}


data "azurerm_subnet" "existing_vnet_subnet" {
    name                 = "${var.subnet_name}"
    virtual_network_name = "${var.vnet_name}"
    resource_group_name  = "${var.network_rg}"
}

data "azurerm_resource_group" "vnet_rg" {
    name = "${var.network_rg}"
}

resource "azurerm_kubernetes_cluster" "aks_c" {
  name                = "${var.prefix}-cluster"
  location            = azurerm_resource_group.aks_rg.location
  resource_group_name = azurerm_resource_group.aks_rg.name
  dns_prefix          = "${var.prefix}"
  node_resource_group = "${var.prefix}-nodes-rg"
  kubernetes_version  = "${var.kubernetes_version}"
  identity            {
    type = "SystemAssigned"
  }
  linux_profile {
    admin_username = "azureuser"
    ssh_key {
      key_data = "${var.ssh_key}"
    }
  }

  

  role_based_access_control {
    enabled = "true"
    azure_active_directory {
      managed = "true"
      admin_group_object_ids = ["80339304-66f8-4289-ab60-f3b6087d6741"]
    }
  }

  addon_profile {
    azure_policy {
      enabled = true
    }
    
  }

  private_cluster_enabled = "${var.private_cluster}"

  provisioner "local-exec" {
    # Load credentials to local environment so subsequent kubectl commands can be run
    command = <<EOS
      az aks get-credentials --resource-group ${azurerm_resource_group.aks_rg.name} --name ${self.name} --admin --overwrite-existing;
EOS
  }
  provisioner "local-exec" {
    # Load credentials to local environment so subsequent kubectl commands can be run
    when = create
    command = "kubectl apply -f https://raw.githubusercontent.com/Azure/aad-pod-identity/master/deploy/infra/deployment-rbac.yaml"
  }

  provisioner "local-exec" {
    # Load credentials to local environment so subsequent kubectl commands can be run
    when = create
    command = "kubectl apply -f https://raw.githubusercontent.com/Azure/aad-pod-identity/master/deploy/infra/mic-exception.yaml"
  }

  provisioner "local-exec" {
    when = create
    command = "az aks update -n ${azurerm_kubernetes_cluster.aks_c.name} -g ${azurerm_resource_group.aks_rg.name} --attach-acr ${var.acr_id}"
  }

  provisioner "local-exec" {
    when = create
    command = <<EOF
     aksid=$(az aks show -g ${azurerm_resource_group.aks_rg.name} -n ${azurerm_kubernetes_cluster.aks_c.name} --query identityProfile.kubeletidentity.clientId -otsv);
     aksvmssrg=$(az group show --name ${azurerm_kubernetes_cluster.aks_c.node_resource_group} --query id --output tsv);     
     az role assignment create --role "Virtual Machine Contributor" --assignee $aksid --scope ${data.azurerm_resource_group.vnet_rg.id};
     az role assignment create --role "Virtual Machine Contributor" --assignee $aksid --scope $aksvmssrg;
     az role assignment create --role "Managed Identity Operator" --assignee $aksid --scope $aksvmssrg
     
    EOF
  }

  network_profile  {
    network_plugin = "azure"
    service_cidr = "${var.service_cidr}"
    dns_service_ip = "${var.dns_service_ip}"
    docker_bridge_cidr = "${var.docker_bridge_cidr}"
    load_balancer_sku = "standard"
    #outbound_type = "userDefinedRouting"
    outbound_type = "${var.outboundtype}"
  }
  
  default_node_pool {
    name                  = "defaultpool"
    vm_size               = "${var.machine_type}"
    node_count            = var.default_node_pool_size
    vnet_subnet_id        = data.azurerm_subnet.existing_vnet_subnet.id
  }

  tags = {
    Environment = "Production"
  }
}

resource "azurerm_user_assigned_identity" "mi_identity" {
  resource_group_name = azurerm_kubernetes_cluster.aks_c.node_resource_group
  location            = azurerm_resource_group.aks_rg.location
  name = "${var.prefix}-ui"
}

data "azurerm_subscription" "current_sub" {
}

resource "azurerm_role_assignment" "rbac_assignment" {
  scope                = data.azurerm_subscription.current_sub.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.mi_identity.principal_id
}

resource "azurerm_role_assignment" "aks_rbac_assignment" {
  scope                = data.azurerm_subscription.current_sub.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_kubernetes_cluster.aks_c.identity[0].principal_id
}

output "aks_id" {
  value = azurerm_kubernetes_cluster.aks_c.identity
}
