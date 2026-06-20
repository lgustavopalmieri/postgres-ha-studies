# Replicação multi-região (Aurora Global Database)

Este documento explica como sair de **uma região** para **múltiplas regiões**, conectando com os conceitos do capítulo de **Replication** do *Designing Data-Intensive Applications* (DDIA, cap. 5).

---

## 1. Primeiro, situando no vocabulário do DDIA

O DDIA divide replicação em três modelos. Vale fixar onde cada peça do que construímos se encaixa:

- **Single-leader (líder único):** um nó aceita escrita (leader/primário), os outros são read replicas (followers). É **exatamente** o que temos: tanto no lab (primário + réplicas via Patroni) quanto no Aurora de uma região (writer + readers). Escrita num lugar só, leitura distribuída.
- **Multi-leader (múltiplos líderes):** mais de um nó aceita escrita, normalmente um por região/datacenter. Resolve latência de escrita global, mas cria o problema difícil de **conflito de escrita** (dois líderes alteram a mesma linha ao mesmo tempo).
- **Leaderless (sem líder):** qualquer nó aceita escrita/leitura, com quórum (estilo Dynamo/Cassandra). Não é o nosso caso.

O Aurora Global Database, que veremos aqui, é **single-leader estendido entre regiões**: continua existindo **um único writer** (numa região), e as outras regiões recebem cópias **read-only**. Ou seja, mantém o modelo mental simples do líder único, só que agora atravessando regiões.

---

## 2. O que o Aurora replica, e em qual nível

É importante separar dois níveis de replicação, porque o DDIA fala muito disso:

- **Dentro de uma região (o que já temos):** o storage do Aurora é replicado em **6 cópias por 3 AZs**, de forma síncrona no nível de storage. As réplicas de leitura leem desse storage compartilhado. Por isso o lag intra-região é de milissegundos e adicionar réplica não copia o banco (já discutimos isso).
- **Entre regiões (Global Database):** a região secundária tem seu **próprio** storage (regiões não compartilham disco). O Aurora envia as mudanças da região primária para a secundária de forma **assíncrona**, tipicamente com lag abaixo de 1 segundo. Aqui voltamos ao modelo "streaming de mudanças do líder para o follower" do DDIA — só que cross-region.

Repare no padrão que o DDIA enfatiza: **quanto maior a distância, mais assíncrona a replicação tende a ser**, porque esperar confirmação do outro lado do mundo mataria a latência de escrita.

---

## 3. Topologia do Aurora Global Database

```
         REGIÃO PRIMÁRIA (ex.: us-east-1)
        ┌───────────────────────────────┐
        │  WRITER  +  readers locais     │  <- única região que aceita ESCRITA
        └───────────────┬───────────────┘
                        │  replicação assíncrona cross-region (< 1s típico)
            ┌───────────┴───────────┐
            ▼                       ▼
  REGIÃO SECUNDÁRIA           REGIÃO SECUNDÁRIA
  (ex.: eu-west-1)            (ex.: sa-east-1)
  ┌──────────────────┐       ┌──────────────────┐
  │ readers READ-ONLY│       │ readers READ-ONLY│  <- só LEITURA
  └──────────────────┘       └──────────────────┘
```

- Só a **região primária** aceita escrita (single-leader).
- As **secundárias** servem leitura local de baixa latência (um usuário na Europa lê de `eu-west-1` em vez de cruzar o Atlântico).
- Em desastre regional, você **promove** uma secundária a primária (failover de região).

---

## 4. Para que serve (os dois motivos reais)

### 4.1 Leitura global de baixa latência
Usuários espalhados pelo mundo leem da região mais próxima. Isso ataca diretamente a **latência de leitura**, um tema central do DDIA quando fala de replicação geograficamente distribuída.

### 4.2 Disaster Recovery (DR) cross-region
Se a região primária inteira cair (não só uma AZ — a **região toda**), você promove uma secundária. Duas métricas que o DDIA toca indiretamente e que aqui ficam explícitas:
- **RPO (Recovery Point Objective):** quanto de dado você pode perder. Como a replicação cross-region é **assíncrona**, o RPO não é zero — as últimas escritas que ainda não chegaram à secundária se perdem no failover. Tipicamente segundos.
- **RTO (Recovery Time Objective):** quanto tempo até voltar a operar. Promover uma secundária costuma levar pouco (na casa de minuto).

---

## 5. O trade-off que o DDIA martela: replication lag

Multi-região é onde os problemas de **leitura em réplica atrasada** (DDIA, seção "Problems with Replication Lag") ficam mais visíveis. Os três efeitos clássicos do livro:

- **Read-your-writes (ler a própria escrita):** o usuário escreve na região primária e lê de uma secundária que ainda não recebeu a mudança — e não vê o que acabou de gravar. Solução: leituras que precisam refletir a própria escrita vão para a região/endpoint primário.
- **Monotonic reads (leituras monotônicas):** o usuário faz duas leituras e a segunda parece "voltar no tempo" porque caiu numa réplica mais atrasada. Solução: amarrar o usuário a uma réplica/região consistente durante a sessão.
- **Consistent prefix reads (prefixo consistente):** ordem causal de eventos parecer trocada. Mais relevante em sistemas particionados.

A regra de ouro continua a mesma do lab: **escrita e "ler o que acabei de escrever" → primário; leitura tolerante a pequeno atraso → réplica/região local.**

---

## 6. Como isso muda o código Terraform

Um cluster Aurora normal **não** cruza regiões. Para multi-região, a estrutura muda de três formas. Não precisa ser outro projeto, mas precisa de mais peças.

### 6.1 Múltiplos providers com `alias` (um por região)

```hcl
provider "aws" {
  alias  = "primary"
  region = "us-east-1"
}

provider "aws" {
  alias  = "secondary"
  region = "eu-west-1"
}
```

### 6.2 Um recurso `aws_rds_global_cluster` "guarda-chuva"

```hcl
resource "aws_rds_global_cluster" "this" {
  global_cluster_identifier = "pg-ha-global"
  engine                    = "aurora-postgresql"
  engine_version            = "16.4"
}
```

### 6.3 O módulo Aurora instanciado uma vez por região

```hcl
# Cluster PRIMÁRIO (aceita escrita) - vinculado ao global cluster
module "aurora_primary" {
  source  = "terraform-aws-modules/rds-aurora/aws"
  version = "~> 10.0"

  providers = { aws = aws.primary }

  name                      = "pg-ha-primary"
  engine                    = "aurora-postgresql"
  engine_version            = "16.4"
  global_cluster_identifier = aws_rds_global_cluster.this.id
  is_primary_cluster        = true
  # ... vpc, subnets e instâncias da região primária ...
}

# Cluster SECUNDÁRIO (read-only) - na outra região
module "aurora_secondary" {
  source  = "terraform-aws-modules/rds-aurora/aws"
  version = "~> 10.0"

  providers = { aws = aws.secondary }

  name                      = "pg-ha-secondary"
  engine                    = "aurora-postgresql"
  engine_version            = "16.4"
  global_cluster_identifier = aws_rds_global_cluster.this.id
  is_primary_cluster        = false   # NÃO cria writer; é réplica de leitura da região
  source_region             = "us-east-1"
  # ... vpc e subnets PRÓPRIAS da região secundária ...
}
```

Pontos de atenção nessa estrutura:
- Cada região tem **sua própria VPC/subnets** (VPC não cruza região). Você cria uma VPC por região.
- `is_primary_cluster = false` faz o módulo **não** provisionar writer na secundária — ela só replica e serve leitura.
- A senha/segredo e o `database_name` são definidos só na primária; a secundária herda os dados via replicação.

### 6.4 Endpoints que a aplicação usa

- **Escrita:** sempre o writer endpoint da **região primária**.
- **Leitura:** o reader endpoint da região **mais próxima** do usuário (primária ou secundária).

Ou seja, o padrão de dois DataSources da app continua — mas o endpoint de leitura passa a ser escolhido por região/proximidade.

---

## 7. Mono-projeto ou multi-projeto?

- **Mesmo projeto Terraform:** prático para manter primária e secundárias em sincronia, um `apply` só. Bom quando poucas regiões e um time dono de tudo.
- **Projetos/states separados por região:** reduz "raio de explosão" (um erro de apply não afeta todas as regiões) e permite times/donos distintos. Comum em organizações grandes.

Não há resposta única; é decisão de organização e de quem opera. Comece mono-projeto se for simples; separe quando a complexidade/governança pedir.

---

## 8. Resumo

- Aurora de **uma região** já é Multi-AZ (storage em 3 AZs) — tolera queda de zona. É single-leader (writer + readers), igual ao lab.
- **Multi-região** = Aurora Global Database: single-leader estendido, **uma** região escreve, as outras leem (read-only), replicação **assíncrona** cross-region (< 1s típico).
- Serve para **leitura global de baixa latência** e **DR cross-region** (com RPO > 0 por ser assíncrono).
- Os problemas de **replication lag** do DDIA (read-your-writes, monotonic, consistent prefix) ficam mais evidentes — e a mitigação é a mesma: o que precisa de consistência vai para o primário.
- No Terraform, muda a estrutura: providers com `alias`, um `aws_rds_global_cluster`, e o módulo Aurora por região (primária com writer, secundárias read-only).
- Tudo isso ainda é **replicação** (escala leitura e disponibilidade). O teto de **escrita** continua sendo um único writer — resolver isso é **sharding**, outro assunto.
