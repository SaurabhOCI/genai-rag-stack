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

# Verify Bastion plugin status before creating MANAGED_SSH sessions
resource "null_resource" "verify_bastion_plugin" {
  count = var.enable_bastion_service && var.enable_bastion_sessions ? 1 : 0
  
  provisioner "local-exec" {
    command = <<-EOT
      # Wait for plugin to be RUNNING - retry for up to 5 minutes after initial wait
      for i in {1..30}; do
        plugin_status=$(oci compute-management instance-agent plugin list \
          --instance-agent-id ${oci_core_instance.genai.id} \
          --query 'data[?name==`Bastion`].status | [0]' \
          --raw-output 2>/dev/null || echo "UNKNOWN")
        
        echo "Attempt $i: Bastion plugin status: $plugin_status"
        
        if [ "$plugin_status" = "RUNNING" ]; then
          echo "Bastion plugin is RUNNING - ready for MANAGED_SSH sessions"
          exit 0
        fi
        
        if [ $i -eq 30 ]; then
          echo "Warning: Bastion plugin not in RUNNING state after maximum wait time"
          echo "Will proceed with PORT_FORWARDING sessions only"
          exit 0
        fi
        
        sleep 10
      done
    EOT
  }
  
  depends_on = [time_sleep.wait_for_bastion_plugin]
}

# External data source to check plugin status for conditional session creation
data "external" "bastion_plugin_status" {
  count = var.enable_bastion_service && var.enable_bastion_sessions ? 1 : 0
  
  program = ["bash", "-c", <<-EOT
    plugin_status=$(oci compute-management instance-agent plugin list \
      --instance-agent-id ${oci_core_instance.genai.id} \
      --query 'data[?name==`Bastion`].status | [0]' \
      --raw-output 2>/dev/null || echo "UNKNOWN")
    
    if [ "$plugin_status" = "RUNNING" ]; then
      echo '{"ready": "true", "status": "'$plugin_status'"}'
    else
      echo '{"ready": "false", "status": "'$plugin_status'"}'
    fi
  EOT
  ]
  
  depends_on = [null_resource.verify_bastion_plugin]
}

# Conditional Managed SSH Session - only if plugin is RUNNING
resource "oci_bastion_session" "genai_ssh" {
  count      = var.enable_bastion_service && var.enable_bastion_sessions && length(data.external.bastion_plugin_status) > 0 ? (data.external.bastion_plugin_status[0].result.ready == "true" ? 1 : 0) : 0
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

  timeouts {
    create = "30m"
  }
}

# Alternative SSH via Port Forwarding (always available)
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
}
