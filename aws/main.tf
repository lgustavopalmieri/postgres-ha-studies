# ============================================================================
# Ambiente de produção: Aurora PostgreSQL (writer + réplicas de leitura)
# numa VPC privada Multi-AZ.
#
# Equivalência com o lab (Docker):
#   - lab: pg1 primário + pg2/3/4 réplicas, failover via Patroni
#     -> Aurora: 1 writer + N readers, failover gerenciado pela AWS
#   - lab: HAProxy :5000 escrita / :5001 leitura
#     -> Aurora: writer endpoint (escrita) / reader endpoint (leitura,
#        já balanceado entre as réplicas pela própria AWS)
#   - lab: etcd para consenso/eleição
#     -> Aurora: gerenciado internamente pela AWS (você não opera isso)
# ============================================================================

locals {
  name = "${var.project_name}-${var.environment}"

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# AZs disponíveis na região. Pegamos as N primeiras (az_count) para distribuir
# as instâncias do cluster e garantir tolerância a falha de zona.
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)
}

# --- Rede -------------------------------------------------------------------
# VPC com subnets privadas (banco) e públicas (apenas para NAT/saída).
# O banco fica SOMENTE em subnets privadas: sem rota direta da internet.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = "${local.name}-vpc"
  cidr = var.vpc_cidr
  azs  = local.azs

  # /20 privadas para o banco e futuras cargas internas; /24 públicas só p/ NAT.
  private_subnets = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i + 48)]

  # NAT único para reduzir custo no ambiente de exemplo. Em produção crítica,
  # considere um NAT por AZ (one_nat_gateway_per_az = true) para HA da saída.
  enable_nat_gateway = true
  single_nat_gateway = true

  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = local.common_tags
}

# --- Banco: Aurora PostgreSQL ----------------------------------------------
# O módulo cria o cluster, as instâncias (writer + readers), o subnet group,
# o security group, o parameter group e gerencia a senha master no
# Secrets Manager (manage_master_user_password = true por padrão).
module "aurora" {
  source  = "terraform-aws-modules/rds-aurora/aws"
  version = "~> 10.0"

  name            = local.name
  engine          = "aurora-postgresql"
  engine_version  = var.engine_version
  database_name   = var.db_name
  master_username = var.db_master_username

  # Senha gerenciada pela AWS no Secrets Manager (com rotação possível).
  # Nada de senha em código ou em state legível.
  manage_master_user_password = true

  # Rede: cluster apenas nas subnets privadas.
  vpc_id                 = module.vpc.vpc_id
  subnets                = module.vpc.private_subnets
  create_db_subnet_group = true

  # Instâncias do cluster: 1 writer + var.replica_count readers.
  # Todas com a mesma classe. A AZ é distribuída automaticamente.
  instances = merge(
    { writer = { instance_class = var.instance_class } },
    { for i in range(var.replica_count) :
      "reader-${i}" => { instance_class = var.instance_class }
    }
  )

  # Segurança de rede: só aceita conexão na porta 5432 vinda dos CIDRs da app.
  create_security_group = true
  security_group_ingress_rules = {
    from_app = {
      description = "PostgreSQL a partir das subnets da aplicacao"
      from_port   = 5432
      to_port     = 5432
      ip_protocol = "tcp"
      cidr_ipv4   = var.app_ingress_cidrs[0]
    }
  }

  # Criptografia em repouso ligada (KMS gerenciado pela AWS por padrão).
  storage_encrypted = true

  # Backups e proteção.
  backup_retention_period   = var.backup_retention_days
  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.skip_final_snapshot
  # Só define nome de snapshot final quando ele realmente será criado.
  # Com skip_final_snapshot=true, deixamos null para não conflitar em destroy/apply repetidos.
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${local.name}-final"

  # Observabilidade: exporta logs do Postgres e liga Performance Insights.
  enabled_cloudwatch_logs_exports = ["postgresql"]
  create_cloudwatch_log_group     = true

  # Monitoramento avançado por instância.
  cluster_performance_insights_enabled = true
  cluster_monitoring_interval          = 60

  # Parameter group do cluster: força SSL nas conexões.
  cluster_parameter_group = {
    family = "aurora-postgresql16"
    parameters = [
      {
        name         = "rds.force_ssl"
        value        = "1"
        apply_method = "pending-reboot"
      }
    ]
  }

  apply_immediately = true

  tags = local.common_tags
}
