# Provider AWS. A região vem de variável para o mesmo código servir a
# múltiplos ambientes/regiões. Credenciais NUNCA ficam aqui: o provider lê do
# ambiente padrão da AWS (variáveis AWS_*, perfil ~/.aws/credentials, SSO, ou
# role assumida pelo runner de CI). Isso evita segredo em código.
provider "aws" {
  region = var.aws_region

  # Tags aplicadas automaticamente a TODO recurso criado por este provider.
  # Facilita rastrear custo e dono dos recursos.
  default_tags {
    tags = local.common_tags
  }
}
