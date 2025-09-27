resource "oci_identity_compartment" "project" {
  count          = var.create_compartment ? 1 : 0
  provider       = oci.home
  compartment_id = local.parent_for_project
  description    = "GenAI RAG project compartment with Bastion Service"
  name           = var.compartment_name
}

resource "oci_identity_dynamic_group" "dg" {
  count         = var.create_policies ? 1 : 0
  provider      = oci.home
  compartment_id = var.tenancy_ocid
  description   = "GenAI RAG Dynamic Group with Bastion Access"
  name          = "genai-rag-dg-${substr(replace(local.project_compartment_ocid, "ocid1.compartment.oc1..", ""), 0, 8)}"
  matching_rule = "ANY {instance.compartment.id = '${local.project_compartment_ocid}'}"
}

resource "oci_identity_policy" "dg_policies" {
  count         = var.create_policies ? 1 : 0
  provider      = oci.home
  compartment_id = var.tenancy_ocid
  description   = "Allow DG to use Generative AI and Bastion services"
  name          = "genai-rag-dg-policies-${substr(replace(local.project_compartment_ocid, "ocid1.compartment.oc1..", ""), 0, 8)}"
  statements = [
    "allow dynamic-group ${oci_identity_dynamic_group.dg[0].name} to use generative-ai-family in tenancy",
    "allow dynamic-group ${oci_identity_dynamic_group.dg[0].name} to read compartments in tenancy",
    "allow dynamic-group ${oci_identity_dynamic_group.dg[0].name} to manage object-family in compartment id ${local.project_compartment_ocid}",
    "allow dynamic-group ${oci_identity_dynamic_group.dg[0].name} to use bastion in compartment id ${local.project_compartment_ocid}",
    "allow dynamic-group ${oci_identity_dynamic_group.dg[0].name} to manage bastion-session in compartment id ${local.project_compartment_ocid}"
  ]
}

# Additional Bastion-specific policies for users
resource "oci_identity_policy" "bastion_user_policies" {
  count         = var.create_policies && var.enable_bastion_service ? 1 : 0
  provider      = oci.home
  compartment_id = local.project_compartment_ocid
  description   = "Bastion user access policies"
  name          = "genai-bastion-user-policies-${substr(replace(local.project_compartment_ocid, "ocid1.compartment.oc1..", ""), 0, 8)}"
  statements = [
    "allow any-user to use bastion in compartment id ${local.project_compartment_ocid}",
    "allow any-user to manage bastion-session in compartment id ${local.project_compartment_ocid}",
    "allow any-user to read instances in compartment id ${local.project_compartment_ocid}",
    "allow any-user to read subnets in compartment id ${local.project_compartment_ocid}",
    "allow any-user to read instance-agent-plugins in compartment id ${local.project_compartment_ocid}"
  ]
}
