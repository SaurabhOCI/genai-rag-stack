# OCI Bastion Service
resource "oci_bastion_bastion" "genai_bastion" {
  count                        = var.enable_bastion_service ? 1 : 0
  bastion_type                 = "STANDARD"
  compartment_id               = local.project_compartment_ocid
  target_subnet_id             = oci_core_subnet.private.id
  name                         = "genai-rag-bastion"
  client_cidr_block_allow_list = local.allowed_ssh_cidrs_list
  max_session_ttl_in_seconds   = local.bastion_session_ttl_seconds
  
  freeform_tags = {
    Environment = "genai-rag"
    Purpose     = "secure-access"
    Stack       = "terraform"
  }
  
  depends_on = [
    oci_core_subnet.private,
    oci_core_route_table.private
  ]
}

# Managed SSH Session for direct instance access
resource "oci_bastion_session" "genai_ssh" {
  count      = var.enable_bastion_service && var.enable_bastion_sessions ? 1 : 0
  bastion_id = oci_bastion_bastion.genai_bastion[0].id
  
  key_details {
    public_key_content = var.ssh_public_key
  }

  target_resource_details {
    session_type                                = "MANAGED_SSH"
    target_resource_id                          = oci_core_instance.genai.id
    target_resource_operating_system_user_name = "opc"
    target_resource_port                        = 22
  }

  display_name           = "genai-ssh-access"
  session_ttl_in_seconds = local.bastion_session_ttl_seconds
  
  freeform_tags = {
    Purpose = "ssh-access"
    Service = "genai-instance"
  }
}

# Port Forwarding Session for Jupyter Lab
resource "oci_bastion_session" "jupyter_tunnel" {
  count      = var.enable_bastion_service && var.enable_bastion_sessions && contains(local.open_tcp_ports, 8888) ? 1 : 0
  bastion_id = oci_bastion_bastion.genai_bastion[0].id
  
  key_details {
    public_key_content = var.ssh_public_key
  }

  target_resource_details {
    session_type                       = "PORT_FORWARDING"
    target_resource_id                 = oci_core_instance.genai.id
    target_resource_port               = 8888
    target_resource_private_ip_address = oci_core_instance.genai.private_ip
  }

  display_name           = "jupyter-web-access"
  session_ttl_in_seconds = local.bastion_session_ttl_seconds
  
  freeform_tags = {
    Purpose = "web-access"
    Service = "jupyter-lab"
  }
}

# Port Forwarding Session for Streamlit
resource "oci_bastion_session" "streamlit_tunnel" {
  count      = var.enable_bastion_service && var.enable_bastion_sessions && contains(local.open_tcp_ports, 8501) ? 1 : 0
  bastion_id = oci_bastion_bastion.genai_bastion[0].id
  
  key_details {
    public_key_content = var.ssh_public_key
  }

  target_resource_details {
    session_type                       = "PORT_FORWARDING"
    target_resource_id                 = oci_core_instance.genai.id
    target_resource_port               = 8501
    target_resource_private_ip_address = oci_core_instance.genai.private_ip
  }

  display_name           = "streamlit-web-access"
  session_ttl_in_seconds = local.bastion_session_ttl_seconds
  
  freeform_tags = {
    Purpose = "web-access"
    Service = "streamlit"
  }
}

# Port Forwarding Session for Oracle Database
resource "oci_bastion_session" "database_tunnel" {
  count      = var.enable_bastion_service && var.enable_bastion_sessions && contains(local.open_tcp_ports, 1521) ? 1 : 0
  bastion_id = oci_bastion_bastion.genai_bastion[0].id
  
  key_details {
    public_key_content = var.ssh_public_key
  }

  target_resource_details {
    session_type                       = "PORT_FORWARDING"
    target_resource_id                 = oci_core_instance.genai.id
    target_resource_port               = 1521
    target_resource_private_ip_address = oci_core_instance.genai.private_ip
  }

  display_name           = "oracle-db-access"
  session_ttl_in_seconds = local.bastion_session_ttl_seconds
  
  freeform_tags = {
    Purpose = "database-access"
    Service = "oracle-23ai"
  }
}

# Dynamic Port Forwarding Session (SOCKS5)
resource "oci_bastion_session" "dynamic_tunnel" {
  count      = var.enable_bastion_service && var.enable_bastion_sessions ? 1 : 0
  bastion_id = oci_bastion_bastion.genai_bastion[0].id
  
  key_details {
    public_key_content = var.ssh_public_key
  }

  target_resource_details {
    session_type = "DYNAMIC_PORT_FORWARDING"
  }

  display_name           = "genai-socks-tunnel"
  session_ttl_in_seconds = local.bastion_session_ttl_seconds
  
  freeform_tags = {
    Purpose = "dynamic-forwarding"
    Service = "development"
  }
}
