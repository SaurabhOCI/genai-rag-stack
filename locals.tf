locals {
  # Compartment logic
  parent_for_project       = trimspace(var.parent_compartment_ocid) != "" ? var.parent_compartment_ocid : var.tenancy_ocid
  project_compartment_ocid = var.create_compartment ? oci_identity_compartment.project[0].id : var.project_compartment_ocid

  # Parse IP ranges - fixed trim function calls
  allowed_ssh_cidrs_list = [for cidr in split(",", var.allowed_ssh_cidrs) : trimspace(cidr)]
  allowed_web_cidrs_list = [for cidr in split(",", var.allowed_web_cidrs) : trimspace(cidr)]
  
  # Parse TCP ports
  ports_strings  = [for p in split(",", var.open_tcp_ports_csv) : trimspace(p)]
  open_tcp_ports = [for p in local.ports_strings : tonumber(p)]

  # Bastion session TTL in seconds
  bastion_session_ttl_seconds = var.bastion_session_ttl * 3600

  # Conditional deployment flags
  deploy_private_architecture = var.enable_bastion_service
  
  # Authentication settings
  jupyter_password_set = trimspace(var.jupyter_password) != ""
}
