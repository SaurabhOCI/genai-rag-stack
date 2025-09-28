variable "tenancy_ocid" {
  description = "OCID of your tenancy (root)."
  type        = string
}

variable "home_region" {
  description = "Your tenancy's home region (e.g., ap-hyderabad-1)."
  type        = string
}

variable "region" {
  description = "Deployment region (e.g., ap-hyderabad-1)."
  type        = string
}

variable "ssh_public_key" {
  description = "Your SSH public key (ssh-rsa ...)."
  type        = string
}

# Bastion Service Variables
variable "enable_bastion_service" {
  description = "Enable OCI Bastion Service for secure access"
  type        = bool
  default     = true
}

variable "enable_bastion_sessions" {
  description = "Create default bastion sessions automatically"
  type        = bool
  default     = true
}

variable "bastion_session_ttl" {
  description = "Bastion session TTL in hours (1-3 hours)"
  type        = number
  default     = 3
  
  validation {
    condition     = var.bastion_session_ttl >= 1 && var.bastion_session_ttl <= 3
    error_message = "Bastion session TTL must be between 1 and 3 hours."
  }
}

# IP Access Control
variable "allowed_ssh_cidrs" {
  description = "Comma-separated list of CIDR blocks allowed SSH access"
  type        = string
  default     = "0.0.0.0/0"
}

variable "allowed_web_cidrs" {
  description = "Comma-separated list of CIDR blocks allowed web access"
  type        = string
  default     = "0.0.0.0/0"
}

# Network Configuration
variable "enable_nat_gateway" {
  description = "Enable NAT Gateway for private subnet internet access"
  type        = bool
  default     = true
}

# Authentication
variable "jupyter_enable_auth" {
  description = "Enable authentication for Jupyter Lab"
  type        = bool
  default     = true
}

variable "jupyter_password" {
  description = "Password for Jupyter Lab access"
  type        = string
  default     = ""
  sensitive   = true
}

# Compartment Configuration
variable "create_compartment" {
  description = "Whether to create a new project compartment."
  type        = bool
  default     = true
}

variable "parent_compartment_ocid" {
  description = "Parent compartment OCID for new project compartment. Leave blank to use tenancy root."
  type        = string
  default     = ""
}

variable "project_compartment_ocid" {
  description = "Existing compartment OCID when create_compartment=false."
  type        = string
  default     = ""
}

variable "enable_managed_ssh" {
  description = "Enable MANAGED_SSH sessions (requires Bastion plugin to be RUNNING)"
  type        = bool
  default     = false  # Disabled by default to avoid timing issues
}

variable "compartment_name" {
  description = "Project compartment name."
  type        = string
  default     = "genai-rag-project"
}

# Instance Configuration
variable "instance_shape" {
  description = "Compute shape."
  type        = string
  default     = "VM.Standard.E5.Flex"
}

variable "instance_ocpus" {
  description = "OCPUs for Flex shape."
  type        = number
  default     = 2
}

variable "instance_memory_gbs" {
  description = "Memory (GB) for Flex shape."
  type        = number
  default     = 24
}

variable "boot_volume_size_gbs" {
  description = "Boot volume size (GB)."
  type        = number
  default     = 100
}

variable "open_tcp_ports_csv" {
  description = "TCP ports to open (CSV), e.g. 22,8888,8501,1521"
  type        = string
  default     = "22,8888,8501,1521"
}

variable "create_policies" {
  description = "Create instance-principal DG and Policies for Generative AI?"
  type        = bool
  default     = true
}

# Image override (from original stack)
variable "image_ocid" {
  description = "Optional override: if set, use this image OCID instead of auto-discovery."
  type        = string
  default     = ""
}
