
variable "location" {
  type        = string
  description = "Azure region (e.g. westeurope, northeurope, germanywestcentral)"
  default     = "westeurope"
}

variable "resource_group_name" {
  type        = string
  description = "Resource group name"
  default     = "projekat2-rg"
}

variable "prefix" {
  type        = string
  description = "Prefix for all Azure resources"
  default     = "p2"
}

variable "admin_username" {
  type        = string
  description = "Linux admin username"
  default     = "azureuser"
}

variable "ssh_public_key_path" {
  type        = string
  description = "Path to your public SSH key (used for both VMs)"
}

variable "vm_size" {
  type        = string
  description = "VM size (keep small for free trial)"
  default     = "Standard_B1s"
}

variable "allowed_ssh_cidr" {
  type        = string
  description = "CIDR allowed to SSH into VMs (set to your public IP/32 for security)"
  default     = "0.0.0.0/0"
}

variable "app_port" {
  type        = number
  description = "Application TCP port"
  default     = 8080
}
