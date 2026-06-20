# ============================================================================
# A "cola" entre Terraform e Ansible.
#
# Depois de criar as VMs, o Terraform sabe o IP de cada uma. Geramos
# automaticamente o INVENTÁRIO do Ansible (hosts.ini) com esses IPs, agrupados
# por papel. Assim o Ansible já encontra as máquinas sem você digitar IP à mão.
# ============================================================================

locals {
  # IP da primeira interface de rede de cada VM (após o lease do DHCP).
  node_ips = {
    for name, vm in libvirt_domain.vm :
    name => vm.network_interface[0].addresses[0]
  }

  # Particiona os IPs por papel para montar os grupos do inventário.
  etcd_hosts = [
    for name, cfg in local.nodes : "${name} ansible_host=${local.node_ips[name]}"
    if cfg.role == "etcd"
  ]
  postgres_hosts = [
    for name, cfg in local.nodes : "${name} ansible_host=${local.node_ips[name]}"
    if cfg.role == "postgres"
  ]
  haproxy_hosts = [
    for name, cfg in local.nodes : "${name} ansible_host=${local.node_ips[name]}"
    if cfg.role == "haproxy"
  ]
}

# Gera o arquivo de inventário do Ansible em ../ansible/inventory/hosts.ini
resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../ansible/inventory/hosts.ini"
  content  = <<-EOT
    # GERADO AUTOMATICAMENTE pelo Terraform. Não edite à mão.
    [etcd]
    ${join("\n", local.etcd_hosts)}

    [postgres]
    ${join("\n", local.postgres_hosts)}

    [haproxy]
    ${join("\n", local.haproxy_hosts)}

    [all:vars]
    ansible_user=ansible
    ansible_python_interpreter=/usr/bin/python3
    ansible_ssh_common_args='-o StrictHostKeyChecking=no'
  EOT
}

output "node_ips" {
  description = "IP de cada VM criada, por nome."
  value       = local.node_ips
}

output "ansible_inventory_path" {
  description = "Caminho do inventário gerado para o Ansible."
  value       = local_file.ansible_inventory.filename
}
