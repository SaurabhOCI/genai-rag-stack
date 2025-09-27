# VCN
resource "oci_core_vcn" "vcn" {
  compartment_id = local.project_compartment_ocid
  display_name   = "GENAILABS-VCN"
  cidr_blocks    = ["10.0.0.0/16"]
  dns_label      = "genailabs"
}

# Internet Gateway
resource "oci_core_internet_gateway" "igw" {
  compartment_id = local.project_compartment_ocid
  vcn_id         = oci_core_vcn.vcn.id
  enabled        = true
  display_name   = "GENAILABS-IGW"
}

# NAT Gateway (conditional)
resource "oci_core_nat_gateway" "nat" {
  count          = var.enable_nat_gateway && local.deploy_private_architecture ? 1 : 0
  compartment_id = local.project_compartment_ocid
  vcn_id         = oci_core_vcn.vcn.id
  display_name   = "GENAILABS-NAT"
}

# Service Gateway
resource "oci_core_service_gateway" "service_gw" {
  count          = local.deploy_private_architecture ? 1 : 0
  compartment_id = local.project_compartment_ocid
  vcn_id         = oci_core_vcn.vcn.id
  display_name   = "GENAILABS-SERVICE-GW"
  
  services {
    service_id = data.oci_core_services.all_oci_services[0].services[0].id
  }
}

# Route Table for Public Subnet (when no bastion) or minimal public access
resource "oci_core_route_table" "public" {
  compartment_id = local.project_compartment_ocid
  vcn_id         = oci_core_vcn.vcn.id
  display_name   = "GENAILABS-RT-PUBLIC"
  
  route_rules {
    network_entity_id = oci_core_internet_gateway.igw.id
    description       = "Default route to Internet"
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
  }
}

# Route Table for Private Subnet (when using bastion)
resource "oci_core_route_table" "private" {
  count          = local.deploy_private_architecture ? 1 : 0
  compartment_id = local.project_compartment_ocid
  vcn_id         = oci_core_vcn.vcn.id
  display_name   = "GENAILABS-RT-PRIVATE"
  
  dynamic "route_rules" {
    for_each = var.enable_nat_gateway ? [1] : []
    content {
      network_entity_id = oci_core_nat_gateway.nat[0].id
      description       = "Route to NAT Gateway"
      destination       = "0.0.0.0/0"
      destination_type  = "CIDR_BLOCK"
    }
  }
  
  dynamic "route_rules" {
    for_each = length(oci_core_service_gateway.service_gw) > 0 ? [1] : []
    content {
      network_entity_id = oci_core_service_gateway.service_gw[0].id
      description       = "Route to OCI Services"
      destination       = data.oci_core_services.all_oci_services[0].services[0].cidr_block
      destination_type  = "SERVICE_CIDR_BLOCK"
    }
  }
}

# Public Subnet (minimal - only for NAT/IGW when using bastion)
resource "oci_core_subnet" "public" {
  count                      = local.deploy_private_architecture ? 1 : 0
  compartment_id             = local.project_compartment_ocid
  vcn_id                     = oci_core_vcn.vcn.id
  display_name               = "GENAILABS-SUBNET-PUBLIC"
  cidr_block                 = "10.0.1.0/24"
  prohibit_public_ip_on_vnic = false
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.public[0].id]
  dns_label                  = "public"
}

# Private Subnet (for GenAI instance when using bastion)
resource "oci_core_subnet" "private" {
  compartment_id             = local.project_compartment_ocid
  vcn_id                     = oci_core_vcn.vcn.id
  display_name               = local.deploy_private_architecture ? "GENAILABS-SUBNET-PRIVATE" : "GENAILABS-SUBNET-PUBLIC"
  cidr_block                 = local.deploy_private_architecture ? "10.0.2.0/24" : "10.0.1.0/24"
  prohibit_public_ip_on_vnic = local.deploy_private_architecture
  route_table_id             = local.deploy_private_architecture ? oci_core_route_table.private[0].id : oci_core_route_table.public.id
  security_list_ids          = local.deploy_private_architecture ? [oci_core_security_list.private[0].id] : [oci_core_security_list.public_direct[0].id]
  dns_label                  = local.deploy_private_architecture ? "private" : "genailabs"
}

# Get OCI Services for Service Gateway
data "oci_core_services" "all_oci_services" {
  count = local.deploy_private_architecture ? 1 : 0
  
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

# Security List for minimal public subnet (NAT/IGW traffic only)
resource "oci_core_security_list" "public" {
  count          = local.deploy_private_architecture ? 1 : 0
  compartment_id = local.project_compartment_ocid
  vcn_id         = oci_core_vcn.vcn.id
  display_name   = "GENAILABS-SL-PUBLIC"
  
  # Minimal egress for NAT
  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
    description = "All egress for NAT Gateway"
  }
  
  # No ingress rules needed for NAT-only subnet
}

# Security List for Private Subnet (when using bastion)
resource "oci_core_security_list" "private" {
  count          = local.deploy_private_architecture ? 1 : 0
  compartment_id = local.project_compartment_ocid
  vcn_id         = oci_core_vcn.vcn.id
  display_name   = "GENAILABS-SL-PRIVATE"
  
  # All egress
  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
    description = "All egress from private subnet"
  }
  
  # SSH from bastion service (uses service-specific CIDR)
  ingress_security_rules {
    protocol    = "6"
    source      = "0.0.0.0/0"  # Bastion service manages source filtering
    description = "SSH from Bastion Service"
    tcp_options {
      min = 22
      max = 22
    }
  }
  
  # Application ports from bastion service
  dynamic "ingress_security_rules" {
    for_each = [for port in local.open_tcp_ports : port if port != 22]
    content {
      protocol    = "6"
      source      = "0.0.0.0/0"  # Bastion service manages source filtering
      description = "App port ${ingress_security_rules.value} from Bastion Service"
      tcp_options {
        min = ingress_security_rules.value
        max = ingress_security_rules.value
      }
    }
  }
  
  # Internal subnet communication
  ingress_security_rules {
    protocol    = "all"
    source      = "10.0.2.0/24"
    description = "All traffic within private subnet"
  }
}

# Security List for Direct Access (when bastion disabled)
resource "oci_core_security_list" "public_direct" {
  count          = local.deploy_private_architecture ? 0 : 1
  compartment_id = local.project_compartment_ocid
  vcn_id         = oci_core_vcn.vcn.id
  display_name   = "GENAILABS-SL-DIRECT"
  
  # All egress
  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
    description = "All egress"
  }
  
  # SSH access from allowed CIDRs
  dynamic "ingress_security_rules" {
    for_each = contains(local.open_tcp_ports, 22) ? local.allowed_ssh_cidrs_list : []
    content {
      protocol    = "6"
      source      = ingress_security_rules.value
      description = "SSH access from ${ingress_security_rules.value}"
      tcp_options {
        min = 22
        max = 22
      }
    }
  }
  
  # Web ports from allowed CIDRs
  dynamic "ingress_security_rules" {
    for_each = setproduct(
      [for port in local.open_tcp_ports : port if contains([8888, 8501], port)],
      local.allowed_web_cidrs_list
    )
    content {
      protocol    = "6"
      source      = ingress_security_rules.value[1]
      description = "Web port ${ingress_security_rules.value[0]} from ${ingress_security_rules.value[1]}"
      tcp_options {
        min = ingress_security_rules.value[0]
        max = ingress_security_rules.value[0]
      }
    }
  }
  
  # Other ports from web CIDRs
  dynamic "ingress_security_rules" {
    for_each = setproduct(
      [for port in local.open_tcp_ports : port if !contains([22, 8888, 8501], port)],
      local.allowed_web_cidrs_list
    )
    content {
      protocol    = "6"
      source      = ingress_security_rules.value[1]
      description = "Port ${ingress_security_rules.value[0]} from ${ingress_security_rules.value[1]}"
      tcp_options {
        min = ingress_security_rules.value[0]
        max = ingress_security_rules.value[0]
      }
    }
  }
}
