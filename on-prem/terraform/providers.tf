# Conexão com o hypervisor.
#
# uri define COMO o Terraform fala com o libvirt:
#   - "qemu:///system"                         -> KVM na máquina local
#   - "qemu+ssh://user@host-fisico/system"     -> KVM num servidor remoto via SSH
#
# Em produção on-prem, normalmente é um (ou vários) servidor físico remoto.
provider "libvirt" {
  uri = var.libvirt_uri
}
