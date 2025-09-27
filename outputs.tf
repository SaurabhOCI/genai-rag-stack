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
    oci_bastion_session.genai_ssh[0].ssh_metadata != null ? 
    oci_bastion_session.genai_ssh[0].ssh_metadata : 
    "Session created but SSH command not available yet. Check OCI Console for connection details."
  ) : "Direct SSH: ssh -i ~/.ssh/id_rsa opc@${oci_core_instance.genai.public_ip}"
  sensitive = false
}

output "jupyter_connection_command" {
  description = "Jupyter Lab connection command"
  value = var.enable_bastion_service && var.enable_bastion_sessions && length(oci_bastion_session.jupyter_tunnel) > 0 ? (
    oci_bastion_session.jupyter_tunnel[0].ssh_metadata != null ? 
    "${oci_bastion_session.jupyter_tunnel[0].ssh_metadata} then access http://localhost:8888" : 
    "Session created but SSH command not available yet. Check OCI Console for connection details."
  ) : "Direct access: http://${oci_core_instance.genai.public_ip}:8888"
  sensitive = false
}

output "streamlit_connection_command" {
  description = "Streamlit connection command"
  value = var.enable_bastion_service && var.enable_bastion_sessions && length(oci_bastion_session.streamlit_tunnel) > 0 ? (
    oci_bastion_session.streamlit_tunnel[0].ssh_metadata != null ? 
    "${oci_bastion_session.streamlit_tunnel[0].ssh_metadata} then access http://localhost:8501" : 
    "Session created but SSH command not available yet. Check OCI Console for connection details."
  ) : "Direct access: http://${oci_core_instance.genai.public_ip}:8501"
  sensitive = false
}

output "database_connection_command" {
  description = "Oracle database connection command"
  value = var.enable_bastion_service && var.enable_bastion_sessions && length(oci_bastion_session.database_tunnel) > 0 ? (
    oci_bastion_session.database_tunnel[0].ssh_metadata != null ? 
    "${oci_bastion_session.database_tunnel[0].ssh_metadata} then connect to localhost:1521/FREEPDB1" : 
    "Session created but SSH command not available yet. Check OCI Console for connection details."
  ) : "Direct connection: ${oci_core_instance.genai.public_ip}:1521/FREEPDB1"
  sensitive = false
}

# Bastion Session IDs for manual connection
output "bastion_session_ids" {
  description = "Bastion session IDs for manual connection"
  value = var.enable_bastion_service && var.enable_bastion_sessions ? {
    ssh_session       = length(oci_bastion_session.genai_ssh) > 0 ? oci_bastion_session.genai_ssh[0].id : null
    jupyter_session   = length(oci_bastion_session.jupyter_tunnel) > 0 ? oci_bastion_session.jupyter_tunnel[0].id : null
    streamlit_session = length(oci_bastion_session.streamlit_tunnel) > 0 ? oci_bastion_session.streamlit_tunnel[0].id : null
    database_session  = length(oci_bastion_session.database_tunnel) > 0 ? oci_bastion_session.database_tunnel[0].id : null
    dynamic_session   = length(oci_bastion_session.dynamic_tunnel) > 0 ? oci_bastion_session.dynamic_tunnel[0].id : null
  } : null
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

# Manual connection instructions
output "manual_connection_guide" {
  description = "Manual connection instructions for bastion sessions"
  value = var.enable_bastion_service ? <<-EOT

=== Manual Bastion Connection Guide ===

1. List your bastion sessions:
   oci bastion session list --bastion-id ${oci_bastion_bastion.genai_bastion[0].id}

2. Get SSH connection command:
   oci bastion session get --session-id SESSION_ID

3. Use the connection command from the session details

4. For port forwarding, modify the SSH command:
   - Jupyter:   Add -L 8888:${oci_core_instance.genai.private_ip}:8888
   - Streamlit: Add -L 8501:${oci_core_instance.genai.private_ip}:8501
   - Database:  Add -L 1521:${oci_core_instance.genai.private_ip}:1521

5. Access services at:
   - Jupyter Lab: http://localhost:8888
   - Streamlit:   http://localhost:8501
   - Database:    localhost:1521/FREEPDB1 (user: vector, password: vector)

EOT
 : "Bastion service not enabled. Use direct IP access."
}
