# Camada de INFRAESTRUTURA (provisionamento de VMs).
#
# On-prem não há "cloud API". Usamos o provider libvirt para falar com o
# hypervisor KVM/QEMU do(s) host(s) físico(s) e criar as máquinas virtuais.
# Se sua casa for vSphere ou Proxmox, troca-se o provider aqui — a ideia é a
# mesma: Terraform cria as VMs, Ansible configura o software dentro delas.
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    libvirt = {
      source = "dmacvicar/libvirt"
      # Fixado na linha 0.8.x: usa a sintaxe clássica em blocos
      # (disk {}, network_interface {}). A 0.9.x é uma reescrita incompatível.
      version = "~> 0.8.1"
    }
    # Gera arquivos locais (ex.: o inventário do Ansible) a partir do
    # resultado do provisionamento.
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}
