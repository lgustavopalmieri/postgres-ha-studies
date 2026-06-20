variable "libvirt_uri" {
  description = "URI de conexão com o hypervisor KVM. Ex.: qemu:///system (local) ou qemu+ssh://user@host/system (remoto)."
  type        = string
  default     = "qemu:///system"
}

variable "cluster_name" {
  description = "Prefixo de nomeação das VMs e recursos."
  type        = string
  default     = "pg-ha"
}

variable "base_image_url" {
  description = "Imagem cloud-init base (qcow2). Ubuntu 22.04 cloud image é uma escolha sólida."
  type        = string
  default     = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
}

variable "storage_pool" {
  description = "Nome do storage pool do libvirt onde os discos das VMs serão criados."
  type        = string
  default     = "default"
}

variable "network_name" {
  description = "Nome da rede libvirt onde as VMs serão conectadas."
  type        = string
  default     = "default"
}

# --- Topologia do cluster ---------------------------------------------------
# A regra de ouro on-prem (e do DDIA, para evitar split-brain):
#   - etcd em número ÍMPAR (3 ou 5) para ter quórum.
#   - 1 primário Postgres + N réplicas.
#   - 2 HAProxy (par) + VIP para não ter ponto único de entrada.

variable "etcd_count" {
  description = "Número de nós etcd. Use SEMPRE ímpar (3 ou 5) para haver quórum de consenso."
  type        = number
  default     = 3

  validation {
    condition     = var.etcd_count % 2 == 1 && var.etcd_count >= 3
    error_message = "etcd_count deve ser ímpar e >= 3 (3 ou 5) para garantir quórum."
  }
}

variable "postgres_count" {
  description = "Número de nós PostgreSQL/Patroni (1 vira primário, o resto réplica). Mínimo 3 para HA real."
  type        = number
  default     = 3

  validation {
    condition     = var.postgres_count >= 3
    error_message = "Use ao menos 3 nós Postgres para alta disponibilidade."
  }
}

variable "haproxy_count" {
  description = "Número de nós HAProxy. 2 para alta disponibilidade da camada de entrada."
  type        = number
  default     = 2
}

# --- Recursos por papel -----------------------------------------------------

variable "postgres_vcpus" {
  description = "vCPUs por nó Postgres."
  type        = number
  default     = 4
}

variable "postgres_memory_mb" {
  description = "Memória (MB) por nó Postgres."
  type        = number
  default     = 8192
}

variable "postgres_disk_gb" {
  description = "Disco de dados (GB) por nó Postgres."
  type        = number
  default     = 100
}

variable "etcd_vcpus" {
  description = "vCPUs por nó etcd."
  type        = number
  default     = 2
}

variable "etcd_memory_mb" {
  description = "Memória (MB) por nó etcd."
  type        = number
  default     = 2048
}

variable "haproxy_vcpus" {
  description = "vCPUs por nó HAProxy."
  type        = number
  default     = 2
}

variable "haproxy_memory_mb" {
  description = "Memória (MB) por nó HAProxy."
  type        = number
  default     = 2048
}

variable "ssh_public_key" {
  description = "Chave pública SSH injetada via cloud-init para o Ansible acessar as VMs."
  type        = string
}
