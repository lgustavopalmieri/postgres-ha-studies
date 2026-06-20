# ============================================================================
# Provisionamento das VMs on-prem (KVM/libvirt).
#
# Esta camada NÃO instala banco nenhum. Ela só cria as máquinas virtuais com
# os papéis do cluster e as deixa acessíveis por SSH. A instalação/config fica
# 100% no Ansible (pasta ../ansible). Essa separação é a prática recomendada:
#   Terraform = infraestrutura (VMs, disco, rede)
#   Ansible   = configuração (software dentro das VMs)
#
# Papéis criados:
#   - etcd     (quórum de consenso; ímpar: 3 ou 5)
#   - postgres (Patroni + PostgreSQL; 1 primário + N réplicas)
#   - haproxy  (entrada escrita/leitura; par + VIP para HA)
# ============================================================================

locals {
  # Monta a lista de todas as VMs a criar, com nome, papel e recursos.
  # Usar um mapa único facilita gerar o disco, a VM e o inventário do Ansible.
  nodes = merge(
    { for i in range(var.etcd_count) :
      "${var.cluster_name}-etcd-${i + 1}" => {
        role      = "etcd"
        vcpu      = var.etcd_vcpus
        memory    = var.etcd_memory_mb
        data_disk = 0
      }
    },
    { for i in range(var.postgres_count) :
      "${var.cluster_name}-pg-${i + 1}" => {
        role      = "postgres"
        vcpu      = var.postgres_vcpus
        memory    = var.postgres_memory_mb
        data_disk = var.postgres_disk_gb
      }
    },
    { for i in range(var.haproxy_count) :
      "${var.cluster_name}-haproxy-${i + 1}" => {
        role      = "haproxy"
        vcpu      = var.haproxy_vcpus
        memory    = var.haproxy_memory_mb
        data_disk = 0
      }
    },
  )
}

# Imagem base (Ubuntu cloud image) baixada uma vez para o storage pool.
resource "libvirt_volume" "base" {
  name   = "${var.cluster_name}-base.qcow2"
  pool   = var.storage_pool
  source = var.base_image_url
  format = "qcow2"
}

# Disco do SISTEMA de cada VM, derivado da imagem base (copy-on-write).
resource "libvirt_volume" "os" {
  for_each       = local.nodes
  name           = "${each.key}-os.qcow2"
  pool           = var.storage_pool
  base_volume_id = libvirt_volume.base.id
  format         = "qcow2"
}

# Disco de DADOS dedicado para os nós Postgres (separar dados do SO é boa
# prática: facilita backup, expansão e isola o I/O do banco).
resource "libvirt_volume" "data" {
  for_each = { for name, cfg in local.nodes : name => cfg if cfg.data_disk > 0 }
  name     = "${each.key}-data.qcow2"
  pool     = var.storage_pool
  size     = each.value.data_disk * 1024 * 1024 * 1024 # GB -> bytes
  format   = "qcow2"
}

# cloud-init por VM (define hostname e injeta a chave SSH do Ansible).
resource "libvirt_cloudinit_disk" "init" {
  for_each = local.nodes
  name     = "${each.key}-init.iso"
  pool     = var.storage_pool

  user_data = templatefile("${path.module}/templates/cloud_init.cfg", {
    hostname       = each.key
    ssh_public_key = var.ssh_public_key
  })
}

# A VM em si (libvirt domain).
resource "libvirt_domain" "vm" {
  for_each = local.nodes

  name   = each.key
  memory = each.value.memory
  vcpu   = each.value.vcpu

  cloudinit = libvirt_cloudinit_disk.init[each.key].id

  network_interface {
    network_name   = var.network_name
    wait_for_lease = true # espera obter IP, para conseguirmos montar o inventário
  }

  # Disco do sistema.
  disk {
    volume_id = libvirt_volume.os[each.key].id
  }

  # Disco de dados (apenas Postgres).
  dynamic "disk" {
    for_each = each.value.data_disk > 0 ? [1] : []
    content {
      volume_id = libvirt_volume.data[each.key].id
    }
  }

  # Console serial (útil para debug do boot via `virsh console`).
  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }

  graphics {
    type        = "vnc"
    listen_type = "address"
  }
}
