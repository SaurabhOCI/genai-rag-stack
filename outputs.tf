output "project_compartment_ocid" { 
  value = local.project_compartment_ocid 
}

output "vcn_id" { 
  value = oci_core_vcn.vcn.id 
}

output "private_subnet_id" { 
  value = oci_core_subnet.private.id 
}

output "public_subnet_id" { 
  value = var.enable_bastion_service && length(oci_core_subnet.public) > 0 ? oci_core_subnet.public[0].id : null
}

output "genai_instance_id" { 
  value = oci_core_instance.genai.id 
}

output "genai_instance_private_ip" { 
  value = oci_core_instance.genai.private_ip 
}

output "genai_instance_public_ip" { 
  value = !local.deploy_private_architecture ? oci_core_instance.genai.public_ip : null
}

# Bastion Service Outputs
output "bastion_service_id" {
  value = var.enable_bastion_service ? oci_bastion_bastion.genai_bastion[0].id : null
}

output "bastion_service_name" {
  value = var.enable_bastion_service ? oci_bastion_bastion.genai_bastion[0].name : null
}

# Session Connection Commands
output "ssh_connection_command" {
  description = "SSH connection command via bastion"
  value = var.enable_bastion_service && var.enable_bastion_sessions && length(oci_bastion_session.genai_ssh) > 0 ? (
    length(oci_bastion_session.genai_ssh[0].ssh_metadata) > 0 ? 
    oci_bastion_session.genai_ssh[0].ssh_metadata[0].command : 
    "Session created but SSH metadata not available yet"
  ) : "Direct SSH: ssh -i ~/.ssh/id_rsa opc@${oci_core_instance.genai.public_ip}"
  sensitive = false
}

output "jupyter_connection_command" {
  description = "Jupyter Lab connection command"
  value = var.enable_bastion_service && var.enable_bastion_sessions && length(oci_bastion_session.jupyter_tunnel) > 0 ? (
    length(oci_bastion_session.jupyter_tunnel[0].ssh_metadata) > 0 ? 
    "${oci_bastion_session.jupyter_tunnel[0].ssh_metadata[0].command} then access http://localhost:8888" : 
    "Session created but SSH metadata not available yet"
  ) : "Direct access: http://${oci_core_instance.genai.public_ip}:8888"
  sensitive = false
}

output "streamlit_connection_command" {
  description = "Streamlit connection command"
  value = var.enable_bastion_service && var.enable_bastion_sessions && length(oci_bastion_session.streamlit_tunnel) > 0 ? (
    length(oci_bastion_session.streamlit_tunnel[0].ssh_metadata) > 0 ? 
    "${oci_bastion_session.streamlit_tunnel[0].ssh_metadata[0].command} then access http://localhost:8501" : 
    "Session created but SSH metadata not available yet"
  ) : "Direct access: http://${oci_core_instance.genai.public_ip}:8501"
  sensitive = false
}

output "database_connection_command" {
  description = "Oracle database connection command"
  value = var.enable_bastion_service && var.enable_bastion_sessions && length(oci_bastion_session.database_tunnel) > 0 ? (
    length(oci_bastion_session.database_tunnel[0].ssh_metadata) > 0 ? 
    "${oci_bastion_session.database_tunnel[0].ssh_metadata[0].command} then connect to localhost:1521/FREEPDB1" : 
    "Session created but SSH metadata not available yet"
  ) : "Direct connection: ${oci_core_instance.genai.public_ip}:1521/FREEPDB1"
  sensitive = false
}

# Service URLs for quick access
output "service_urls" {
  description = "Service access URLs"
  value = {
    jupyter_lab = var.enable_bastion_service ? "http://localhost:8888 (via bastion tunnel)" : "http://${oci_core_instance.genai.public_ip}:8888"
    streamlit   = var.enable_bastion_service ? "http://localhost:8501 (via bastion tunnel)" : "http://${oci_core_instance.genai.public_ip}:8501"
    oracle_db   = var.enable_bastion_service ? "localhost:1521/FREEPDB1 (via bastion tunnel)" : "${oci_core_instance.genai.public_ip}:1521/FREEPDB1"
  }
}

output "deployment_summary" {
  description = "Deployment configuration summary"
  value = {
    architecture        = var.enable_bastion_service ? "Private with Bastion Service" : "Public Direct Access"
    bastion_enabled     = var.enable_bastion_service
    nat_gateway_enabled = var.enable_nat_gateway
    jupyter_auth        = var.jupyter_enable_auth
    instance_shape      = var.instance_shape
    instance_ocpus      = var.instance_ocpus
    instance_memory_gb  = var.instance_memory_gbs
  }
}
