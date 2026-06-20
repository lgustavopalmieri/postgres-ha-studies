# Restrições de versão. Fixar versões evita que um `terraform init` futuro
# puxe uma versão incompatível e quebre o plan/apply sem aviso.
terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # O módulo rds-aurora 10.x exige o provider AWS >= 6.28.
      # Travamos na linha 6.x para pegar correções sem saltos major.
      version = "~> 6.28"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
