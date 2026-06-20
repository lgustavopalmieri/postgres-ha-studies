# ============================================================================
# Estado remoto (remote state).
#
# Por que isso importa em produção: o arquivo de state guarda o mapeamento
# entre o seu código e os recursos reais na AWS, e pode conter dados sensíveis.
# Mantê-lo localmente é arriscado (perda, sem trava, sem colaboração). Em
# produção, use um backend remoto com TRAVA (lock) para evitar dois applies
# simultâneos corromperem o state.
#
# Está COMENTADO de propósito: você cria o bucket/tabela uma única vez (fora
# deste projeto, ou num bootstrap separado) e então descomenta e roda
# `terraform init` para migrar o state.
# ============================================================================

# terraform {
#   backend "s3" {
#     bucket       = "minha-empresa-tfstate"      # bucket S3 já existente
#     key          = "pg-ha/prod/terraform.tfstate"
#     region       = "us-east-1"
#     encrypt      = true
#     use_lockfile = true                          # trava de state nativa via S3 (Terraform >= 1.11)
#   }
# }
