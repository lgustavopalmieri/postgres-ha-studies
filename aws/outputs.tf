# ============================================================================
# Saídas. São o "contrato" do projeto: o que a aplicação precisa para conectar.
#
# Repare no paralelo direto com o lab:
#   writer_endpoint  -> equivale ao HAProxy :5000 (ESCRITA, vai para o primário)
#   reader_endpoint  -> equivale ao HAProxy :5001 (LEITURA, balanceada entre réplicas)
# ============================================================================

output "cluster_writer_endpoint" {
  description = "Endpoint de ESCRITA (aponta sempre para o writer/primário atual). Use no DataSource de escrita da app."
  value       = module.aurora.cluster_endpoint
}

output "cluster_reader_endpoint" {
  description = "Endpoint de LEITURA (balanceado automaticamente entre as réplicas). Use no DataSource de leitura da app."
  value       = module.aurora.cluster_reader_endpoint
}

output "cluster_port" {
  description = "Porta do banco."
  value       = module.aurora.cluster_port
}

output "database_name" {
  description = "Nome do banco criado no cluster."
  value       = module.aurora.cluster_database_name
}

output "master_user_secret_arn" {
  description = "ARN do segredo no Secrets Manager com a senha do usuário master. A app/devops lê a senha daqui, nunca de código."
  value       = module.aurora.cluster_master_user_secret
  sensitive   = true
}

output "security_group_id" {
  description = "Security group do cluster. Referencie-o no SG da aplicação para liberar a porta 5432."
  value       = module.aurora.security_group_id
}

output "vpc_id" {
  description = "ID da VPC criada."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Subnets privadas onde o banco (e a app) devem rodar."
  value       = module.vpc.private_subnets
}
