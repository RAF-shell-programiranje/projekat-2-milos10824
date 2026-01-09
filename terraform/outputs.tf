
output "app_public_ip" {
  value = azurerm_public_ip.app_pip.ip_address
}

output "monitor_public_ip" {
  value = azurerm_public_ip.mon_pip.ip_address
}

output "app_private_ip" {
  value = azurerm_network_interface.app_nic.private_ip_address
}

output "monitor_private_ip" {
  value = azurerm_network_interface.mon_nic.private_ip_address
}

output "ssh_app" {
  value = "ssh ${var.admin_username}@${azurerm_public_ip.app_pip.ip_address}"
}

output "ssh_monitor" {
  value = "ssh ${var.admin_username}@${azurerm_public_ip.mon_pip.ip_address}"
}
