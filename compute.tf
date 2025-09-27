# Get availability domains
data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
  provider       = oci.home
}

# GenAI Instance
resource "oci_core_instance" "genai" {
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = local.project_compartment_ocid
  display_name        = "GENAI-RAG-INSTANCE"
  shape               = var.instance_shape

  create_vnic_details {
    subnet_id        = oci_core_subnet.private.id
    assign_public_ip = !local.deploy_private_architecture
    hostname_label   = "genai"
  }

  shape_config {
    ocpus         = var.instance_ocpus
    memory_in_gbs = var.instance_memory_gbs
  }

  source_details {
    source_type             = "image"
    source_id               = local.rg_effective_image_ocid
    boot_volume_size_in_gbs = var.boot_volume_size_gbs
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data = base64encode(templatefile("${path.module}/cloudinit.sh", {
      jupyter_enable_auth = var.jupyter_enable_auth
      jupyter_password    = var.jupyter_password
      bastion_enabled     = var.enable_bastion_service
    }))
  }

  agent_config {
    is_management_disabled = false
    is_monitoring_disabled = false
    
    # Enable required plugins for bastion service
    plugins_config {
      name          = "Bastion"
      desired_state = "ENABLED"
    }
    
    plugins_config {
      name          = "OS Management Service Agent"
      desired_state = "ENABLED"
    }
    
    plugins_config {
      name          = "Compute Instance Monitoring"
      desired_state = "ENABLED"
    }
  }

  launch_options { 
    network_type = "PARAVIRTUALIZED" 
  }
  
  instance_options { 
    are_legacy_imds_endpoints_disabled = true 
  }

  timeouts { 
    create = "60m" 
  }

  freeform_tags = {
    Purpose     = "genai-rag"
    Environment = "production"
    Stack       = "terraform"
  }

  lifecycle {
    precondition {
      condition     = var.create_compartment || (trimspace(var.project_compartment_ocid) != "")
      error_message = "When create_compartment=false you must provide project_compartment_ocid."
    }
  }
}
