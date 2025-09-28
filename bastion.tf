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

  timeouts {
    create = "30m"  # Extended timeout for bastion creation
  }
}

# Wait for Bastion plugin to initialize (Oracle's documented maximum)
resource "time_sleep" "wait_for_bastion_plugin" {
  count           = var.enable_bastion_service && var.enable_bastion_sessions ? 1 : 0
  depends_on      = [oci_core_instance.genai]
  create_duration = "10m"  # Oracle's documented maximum initialization time
}

# Always create PORT_FORWARDING sessions (immediate availability)
# SSH via Port Forwarding (works immediately, no plugin dependency)
resource "oci_bastion_session" "ssh_port_forward" {
  count      = var.enable_bastion_service && var.enable_bastion_sessions ? 1 : 0
  bastion_id = oci_bastion_bastion.genai_bastion[0].id
  
  key_details {
    public_key_content = var.ssh_public_key
  }

  target_resource_details {
    session_type                       = "PORT_FORWARDING"
    target_resource_id                 = oci_core_instance.genai.id
    target_resource_port               = 22
    target_resource_private_ip_address = oci_core_instance.genai.private_ip
  }

  display_name           = "genai-ssh-port-forward"
  session_ttl_in_seconds = local.bastion_session_ttl_seconds

  depends_on = [oci_bastion_bastion.genai_bastion]

  timeouts {
    create = "30m"
  }
}

# Port Forwarding Session for Jupyter Lab (immediate availability)
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

  depends_on = [oci_bastion_bastion.genai_bastion]

  timeouts {
    create = "30m"
  }
}

# Port Forwarding Session for Streamlit (immediate availability)
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

  depends_on = [oci_bastion_bastion.genai_bastion]

  timeouts {
    create = "30m"
  }
}

# Port Forwarding Session for Oracle Database (immediate availability)
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

  depends_on = [oci_bastion_bastion.genai_bastion]

  timeouts {
    create = "30m"
  }
}

# Dynamic Port Forwarding Session (SOCKS5) - immediate availability
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

  depends_on = [oci_bastion_bastion.genai_bastion]

  timeouts {
    create = "30m"
  }
}

# MANAGED_SSH Session - created with wait time but no conditional logic
# This will fail if plugin is not ready, but can be re-applied later
resource "oci_bastion_session" "genai_ssh" {
  count      = var.enable_bastion_service && var.enable_bastion_sessions && var.enable_managed_ssh ? 1 : 0
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

  depends_on = [time_sleep.wait_for_bastion_plugin]

  timeouts {
    create = "30m"
  }

  lifecycle {
    # Allow this resource to fail during creation if plugin is not ready
    # User can re-apply once plugin is initialized
    ignore_changes = []
  }
}
