variable "aws_region" {
  description = "Região AWS onde o ambiente será criado."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefixo usado para nomear e taguear os recursos."
  type        = string
  default     = "pg-ha"
}

variable "environment" {
  description = "Ambiente de implantação."
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment deve ser dev, staging ou prod."
  }
}

# --- Rede ------------------------------------------------------------------

variable "vpc_cidr" {
  description = "Bloco CIDR da VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Quantidade de Availability Zones a usar (mínimo 3 para HA real)."
  type        = number
  default     = 3

  validation {
    condition     = var.az_count >= 3
    error_message = "Use ao menos 3 AZs para alta disponibilidade em produção."
  }
}

# --- Banco de dados (Aurora) -----------------------------------------------

variable "db_name" {
  description = "Nome do banco criado automaticamente no cluster."
  type        = string
  default     = "appdb"
}

variable "db_master_username" {
  description = "Usuário master do cluster. A SENHA não é definida aqui: o RDS a gera e guarda no Secrets Manager."
  type        = string
  default     = "postgres"
}

variable "engine_version" {
  description = "Versão do Aurora PostgreSQL."
  type        = string
  default     = "16.4"
}

variable "instance_class" {
  description = "Classe de instância das instâncias do cluster (writer e readers)."
  type        = string
  default     = "db.r6g.large"
}

variable "replica_count" {
  description = "Número de réplicas de LEITURA além do writer. 2 réplicas + 1 writer = 3 instâncias."
  type        = number
  default     = 2

  validation {
    condition     = var.replica_count >= 1
    error_message = "Tenha ao menos 1 réplica de leitura para escalar leitura e ter failover saudável."
  }
}

variable "backup_retention_days" {
  description = "Dias de retenção de backup automático (habilita PITR)."
  type        = number
  default     = 14
}

variable "deletion_protection" {
  description = "Protege o cluster contra exclusão acidental. Mantenha true em produção."
  type        = bool
  default     = true
}

variable "skip_final_snapshot" {
  description = "Se true, NÃO cria snapshot final ao destruir o cluster (destroy mais rápido e sem custo residual). Mantenha false em produção para ter um backup final."
  type        = bool
  default     = false
}

variable "app_ingress_cidrs" {
  description = "CIDRs autorizados a conectar no banco (ex.: subnets onde a aplicação roda). Restrinja ao mínimo."
  type        = list(string)
  default     = ["10.0.0.0/16"]
}
