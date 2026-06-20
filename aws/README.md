# Ambiente de produção: Aurora PostgreSQL com Terraform

Este projeto provisiona, com Terraform, a versão de **produção** do que você montou no `lab/` com Docker. Em vez de operar Postgres + Patroni + etcd + HAProxy na mão, delegamos isso ao **Amazon Aurora PostgreSQL**, que é um banco gerenciado que já entrega writer + réplicas de leitura, failover automático e backup.

> Nada é aplicado automaticamente. Você revisa, roda `plan` e só aplica quando quiser.

---

## 1. O que este código cria

- Uma **VPC** Multi-AZ com subnets privadas (banco) e públicas (apenas saída via NAT).
- Um **cluster Aurora PostgreSQL** com:
  - 1 instância **writer** (escrita)
  - N instâncias **reader** (leitura) — padrão 2, total de 3 instâncias
- **Security group** que só libera a porta 5432 a partir dos CIDRs da aplicação.
- **Senha master gerenciada no Secrets Manager** (não há senha em código nem no state).
- **Backups automáticos** (PITR), **criptografia em repouso**, **logs no CloudWatch**, **Performance Insights** e **SSL obrigatório**.

Arquivos:

```
terraform/
├── versions.tf       # versões de Terraform e providers (fixadas)
├── providers.tf      # provider AWS + tags padrão
├── backend.tf        # state remoto (comentado, pronto para ligar)
├── variables.tf      # entradas parametrizáveis
├── main.tf           # VPC + cluster Aurora
├── outputs.tf        # endpoints de escrita/leitura e infos de conexão
├── terraform.tfvars.example
└── .gitignore
```

---

## 2. O conceito da arquitetura (breve)

A ideia é a mesma do lab, só muda quem opera:

```
          aplicação
        ┌─────┴──────┐
   ESCRITA        LEITURA
   (writer        (reader
   endpoint)      endpoint)
        │              │
        ▼              ▼
   ┌─────────┐   ┌───────────────────────┐
   │ WRITER  │──►│ READER 1 ... READER N  │
   │(primário)│   │ (réplicas de leitura) │
   └─────────┘   └───────────────────────┘
        replicação interna do Aurora
```

- **Writer endpoint** = o antigo HAProxy `:5000`. Aponta sempre para a instância primária atual. Sua aplicação manda INSERT/UPDATE/DELETE para cá.
- **Reader endpoint** = o antigo HAProxy `:5001`. A AWS já **balanceia** as conexões entre as réplicas. Sua aplicação manda SELECT para cá.
- **Failover**: se o writer cai, o Aurora promove uma réplica e o writer endpoint passa a apontar para ela sozinho — o mesmo papel que o Patroni + etcd faziam no lab, só que gerenciado pela AWS.

O padrão de **dois DataSources** da sua app NestJS continua idêntico: um aponta para o writer endpoint, o outro para o reader endpoint. Só mudam os hosts.

---

## 3. Sobre RDS e Aurora (para aprender)

**RDS (Relational Database Service)** é o serviço de banco gerenciado da AWS. Você escolhe um engine (PostgreSQL, MySQL, etc.) e a AWS cuida de provisionamento, patching, backup e (no modo Multi-AZ) failover. No "RDS clássico", a réplica de leitura e o standby de HA usam replicação parecida com a que você viu no lab (streaming de WAL entre instâncias, cada uma com seu próprio armazenamento).

**Aurora** é um engine próprio da AWS, compatível com PostgreSQL e MySQL, com uma diferença arquitetural importante: ele **separa compute de storage**. As instâncias (writer e readers) compartilham uma **camada de armazenamento distribuída**, replicada em 6 cópias por 3 AZs. Consequências práticas:

- **Lag de réplica baixíssimo.** Como o storage é compartilhado, a réplica não precisa "puxar e aplicar o WAL" como no lab — ela lê do mesmo storage. O atraso costuma ser de milissegundos.
- **Adicionar réplica é rápido.** Lembra do problema do `pg_basebackup` pesando no primário (no `ESCALANDO-REPLICAS.md` do lab)? No Aurora isso quase some: a réplica nova "anexa" ao storage existente em vez de copiar o banco inteiro. Aquele perigo de sufocar o primário ao clonar deixa de existir.
- **Failover rápido.** Promover uma réplica não envolve copiar dados; o storage já está lá.

**Aurora vs RDS clássico — quando usar cada um:**

- **Aurora**: alto volume de leitura, necessidade de escalar réplicas rápido, menor lag, failover mais ágil. É a escolha default para produção de larga escala. Custa mais.
- **RDS PostgreSQL clássico**: cargas menores/previsíveis, quando você quer ficar o mais "Postgres puro" possível ou reduzir custo. Multi-AZ dá HA, mas o standby não serve leitura (é só para failover) — réplicas de leitura são instâncias separadas.

**Aurora Serverless v2**: variação onde a capacidade (compute) escala automaticamente para cima/baixo conforme a carga. Bom para tráfego irregular. Não usamos aqui (fixamos `instance_class`), mas o módulo suporta.

**O que o Aurora NÃO resolve:** escala de **escrita**. Continua havendo **um** writer. Reader endpoint escala leitura; para escalar escrita além de um nó, o caminho é **sharding** (assunto que ficou para depois). Replicação resolve leitura e disponibilidade, não o teto de escrita — exatamente como concluímos no lab.

---

## 4. Como aplicar (quando você decidir)

Pré-requisitos: Terraform >= 1.11, credenciais AWS no ambiente (variáveis `AWS_*`, perfil ou SSO).

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # ajuste os valores

terraform init       # baixa provider e módulos
terraform plan        # revise TUDO que será criado antes de aplicar
terraform apply       # cria a infraestrutura (custa dinheiro!)
```

Para conectar a aplicação depois do apply:

```bash
terraform output cluster_writer_endpoint   # host de ESCRITA
terraform output cluster_reader_endpoint   # host de LEITURA
terraform output -raw master_user_secret_arn   # ARN do segredo com a senha
```

A senha é lida do Secrets Manager (nunca de código). Exemplo:

```bash
aws secretsmanager get-secret-value --secret-id <ARN> --query SecretString --output text
```

Para destruir tudo: com `deletion_protection = false` e `skip_final_snapshot = true` (já definidos no `terraform.tfvars`), basta `terraform destroy` — sem trava e sem snapshot final. Em produção, mantenha `deletion_protection = true` e `skip_final_snapshot = false`; aí, para destruir, ajuste esses valores no `.tfvars`, rode `apply` e só então `terraform destroy`.

---

## 5. Escalando para mais réplicas de leitura

Esta é a operação que no lab exigia adicionar `pg5`, mexer no HAProxy e cuidar do `pg_basebackup` (veja `lab/ESCALANDO-REPLICAS.md`). No Aurora é muito mais simples, e existem duas formas.

### Forma 1: manual e declarativa (recomendada para começar)

Basta aumentar uma variável. O número de instâncias do cluster é derivado de `replica_count`:

```hcl
# terraform.tfvars
replica_count = 4   # antes era 2 -> agora 4 readers + 1 writer = 5 instâncias
```

Depois:

```bash
terraform plan    # mostra a criação de reader-2 e reader-3
terraform apply
```

O que acontece nos bastidores:
- O Terraform adiciona as novas instâncias `reader-N` ao cluster.
- Como o storage do Aurora é compartilhado, a réplica nova **não** faz cópia do banco inteiro — ela "anexa" ao storage existente e fica disponível em minutos, **sem sufocar o writer** (aquele perigo do basebackup no lab some).
- O **reader endpoint passa a incluir a nova réplica automaticamente** no balanceamento. A aplicação não muda nada: continua usando o mesmo reader endpoint.

Para reduzir, é só baixar o número e aplicar. Diminua um de cada vez em horário de baixa, para não derrubar conexões em massa.

### Forma 2: autoscaling automático (réplicas sob demanda)

O Aurora pode criar/remover réplicas de leitura sozinho conforme a carga (CPU ou número de conexões). O módulo expõe isso. Para ligar, acrescente ao bloco `module "aurora"` no `main.tf`:

```hcl
  # Autoscaling de réplicas de LEITURA
  autoscaling_enabled      = true
  autoscaling_min_capacity = 2     # nunca menos que 2 readers
  autoscaling_max_capacity = 8     # cresce até 8 readers no pico
  predefined_metric_type   = "RDSReaderAverageCPUUtilization"
  autoscaling_target_cpu   = 70    # alvo: manter CPU média das réplicas ~70%
```

Com isso, a AWS adiciona réplicas quando a CPU média passa do alvo e remove quando a carga cai, dentro do intervalo min/max. Ótimo para tráfego de leitura irregular (picos sazonais, campanhas, etc.).

> Atenção: ao usar autoscaling, deixe o `replica_count` no valor base (o mínimo) e deixe o autoscaling cuidar do excedente, para o Terraform e o autoscaler não "brigarem" pelo número de instâncias.

### Trade-offs (mesmos princípios do lab, custo menor)

- **Leitura desatualizada (replica lag):** mesmo com lag baixíssimo no Aurora, ele não é zero. Fluxos "read-your-writes" devem ler do writer endpoint. Igual ao que vimos no lab.
- **Cache frio:** uma réplica recém-criada começa com cache vazio; as primeiras queries podem ser mais lentas até aquecer.
- **Custo:** cada réplica é uma instância cobrada. Autoscaling ajuda a pagar só pelo que usa, mas defina um `max_capacity` sensato para não ter surpresa na fatura.
- **Escala leitura, não escrita:** continua havendo um único writer. Mais réplicas = mais leitura; o teto de escrita só se resolve com sharding.

---

## 6. Notas de produção que valem revisão

- **State remoto**: ative o backend S3 em `backend.tf` antes de trabalhar em equipe (evita corromper o state e dá trava).
- **NAT**: usamos um NAT único para baratear. Para HA da saída, use um NAT por AZ.
- **Acesso ao banco**: hoje liberamos o primeiro CIDR de `app_ingress_cidrs`. O ideal é referenciar o **security group da aplicação** em vez de um CIDR, liberando só quem realmente precisa.
- **Versão do engine**: `16.4` é um exemplo; confirme uma versão de Aurora PostgreSQL disponível na sua região antes do apply.
- **Custo**: instâncias `db.r6g.large` + Multi-AZ + backups geram custo relevante. Para um teste barato, reduza `instance_class` e `replica_count`, ou avalie Aurora Serverless v2.
