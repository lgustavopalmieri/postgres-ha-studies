# Ambiente de produção ON-PREMISE (Terraform + Ansible)

Esta é a versão **on-premise** (sem nuvem) da nossa arquitetura: PostgreSQL + Patroni + etcd + HAProxy, igual ao `lab/`, mas instalada de verdade em **máquinas virtuais** que você roda no seu próprio hardware.

> Nada é aplicado automaticamente. Você revisa, roda os planos e aplica quando quiser.

---

## 1. A divisão de responsabilidades (o conceito central)

On-premise não existe "API da nuvem" que cria servidores. Então o trabalho se divide em duas ferramentas, cada uma no que faz de melhor:

```
   TERRAFORM                          ANSIBLE
   (infraestrutura)                   (configuração)
   ┌─────────────────┐                ┌──────────────────────┐
   │ cria as VMs no  │  gera o        │ instala e configura  │
   │ hypervisor KVM  │ ─inventário──► │ etcd, Patroni/PG,    │
   │ (libvirt)       │  (hosts.ini)   │ HAProxy + keepalived │
   └─────────────────┘                └──────────────────────┘
```

- **Terraform**: fala com o hypervisor (KVM via libvirt) e cria as máquinas virtuais vazias, com disco, rede e acesso SSH. Não instala banco.
- **Ansible**: entra nas VMs por SSH e instala/configura todo o software.
- A "cola": o Terraform **gera automaticamente o inventário do Ansible** (`ansible/inventory/hosts.ini`) com os IPs reais das VMs criadas.

Por que essa separação? Provisionar máquina e configurar software são problemas diferentes. Terraform é declarativo para infraestrutura; Ansible é excelente para configuração idempotente dentro do SO. Misturar os dois numa ferramenta só costuma dar dor de cabeça.

---

## 2. A topologia (e por que cada número)

```
                       ┌──────────────────────────────┐
   aplicação ────VIP──►│  HAProxy 1  +  HAProxy 2      │  (keepalived mantém 1 VIP)
   (escrita :5000)     │   :5000 escrita / :5001 leit. │
   (leitura :5001)     └───────────────┬──────────────┘
                ┌───────────────┬───────┴───────┬───────────────┐
                ▼               ▼               ▼
            ┌────────┐      ┌────────┐      ┌────────┐
            │  pg-1  │      │  pg-2  │      │  pg-3  │   PostgreSQL + Patroni
            │primário│ ───► │réplica │ ───► │réplica │   (1 primário + N réplicas)
            └────────┘      └────────┘      └────────┘
                │  Patroni usa o etcd para eleição/consenso
        ┌───────┴────────┬────────────────┐
        ▼                ▼                ▼
   ┌────────┐       ┌────────┐       ┌────────┐
   │ etcd-1 │       │ etcd-2 │       │ etcd-3 │   consenso (quórum ímpar!)
   └────────┘       └────────┘       └────────┘
```

Decisões de produção embutidas:
- **etcd em número ímpar (3 ou 5):** consenso (Raft) precisa de maioria/quórum. Com 3 nós, você tolera a queda de 1. Com 2 (par) você não ganha tolerância e ainda arrisca empate — por isso há validação no Terraform impedindo número par.
- **3+ nós PostgreSQL:** 1 primário + 2 réplicas dá failover saudável e capacidade de leitura.
- **2 HAProxy + VIP (keepalived):** evita que a camada de entrada seja ponto único de falha. O **VIP** (IP virtual) é o endereço estável que a aplicação usa; ele "flutua" para o HAProxy de backup se o principal cair.

Isto resolve, on-prem, o problema que no `lab/` tínhamos (HAProxy e etcd únicos) e que apontamos como inaceitável para produção.

---

## 3. Estrutura do projeto

```
on-prem/
├── terraform/                 # CRIA as VMs (KVM/libvirt)
│   ├── versions.tf            # provider libvirt 0.8.x (sintaxe em blocos)
│   ├── providers.tf           # conexão com o hypervisor (uri)
│   ├── variables.tf           # topologia e recursos por nó
│   ├── main.tf                # imagem base, discos, cloud-init e VMs
│   ├── outputs.tf             # GERA o inventário do Ansible
│   ├── templates/cloud_init.cfg
│   └── terraform.tfvars.example
└── ansible/                   # CONFIGURA o software nas VMs
    ├── ansible.cfg
    ├── site.yml               # playbook principal (ordem: etcd→pg→haproxy)
    ├── group_vars/all.yml     # versões, portas, senhas (use Vault!), VIP
    ├── inventory/             # hosts.ini é gerado pelo Terraform
    └── roles/
        ├── etcd/              # cluster etcd via systemd
        ├── patroni/           # PostgreSQL + Patroni via systemd
        └── haproxy/           # HAProxy + keepalived (VIP)
```

---

## 4. Pré-requisitos no host físico

- **KVM/QEMU + libvirt** instalados e rodando (`libvirtd`).
- Um **storage pool** do libvirt (o padrão `default` serve) e uma **rede** libvirt (a `default` com DHCP serve).
- **Terraform >= 1.6** e **Ansible** instalados na sua máquina de operação.
- Uma **chave SSH** (a pública é injetada nas VMs; a privada o Ansible usa).

> Se sua casa não for KVM e sim **vSphere** ou **Proxmox**, troca-se apenas o provider no `terraform/` (ex.: `vsphere` ou `telmate/proxmox`). A camada Ansible permanece idêntica — essa é a vantagem de separar as responsabilidades.

---

## 5. Como aplicar (quando decidir)

### Passo 1 — Criar as VMs com Terraform

```bash
cd on-prem/terraform
cp terraform.tfvars.example terraform.tfvars   # ajuste a chave SSH e a topologia

terraform init
terraform plan      # revise as VMs que serão criadas
terraform apply     # cria as VMs e gera ../ansible/inventory/hosts.ini
```

### Passo 2 — Configurar o software com Ansible

```bash
cd ../ansible
# ajuste group_vars/all.yml (senhas via Vault, VIP livre na sua rede)
ansible-playbook site.yml
```

A ordem do playbook importa e já está definida: **etcd → PostgreSQL/Patroni → HAProxy**.

### Passo 3 — Verificar

```bash
# Estado do cluster Patroni (rode em qualquer nó pg)
ssh ansible@<ip-de-um-pg> "sudo patronictl -c /etc/patroni/patroni.yml list"
```

A aplicação conecta no **VIP**: escrita em `VIP:5000`, leitura em `VIP:5001`.

---

## 6. Como a aplicação se conecta

Igual ao lab e ao Aurora: **dois endpoints**.

- Escrita → `haproxy_vip:5000` (sempre o primário)
- Leitura → `haproxy_vip:5001` (réplicas, balanceadas)

A `app-ha` (NestJS) que fizemos funciona aqui sem mudança de código: basta apontar os dois DataSources para o VIP nas portas 5000/5001.

---

## 7. Segurança e produção (pontos a endurecer)

- **Senhas:** `group_vars/all.yml` tem senhas de exemplo. Em produção, cifre com **Ansible Vault** (`ansible-vault encrypt group_vars/all.yml`) e nunca comite em texto puro.
- **etcd sem TLS:** o exemplo usa HTTP entre nós para simplificar. Em produção, habilite TLS mútuo no etcd e autenticação.
- **pg_hba aberto:** liberamos `0.0.0.0/0` na rede interna para facilitar. Restrinja aos CIDRs reais dos nós/aplicação e use SSL no Postgres.
- **Backups:** este projeto sobe o cluster, mas **não** configura backup. Em produção, adicione **pgBackRest** (backup full/incremental + PITR) — é o equivalente on-prem do que o RDS faz por você.
- **Monitoramento:** adicione Prometheus + Grafana (há exporters para Patroni, Postgres e HAProxy) e alarmes de disco (lembre dos replication slots enchendo o disco do primário, como discutimos no lab).
- **NAT/saída e firewall:** ajuste as regras de rede do host conforme sua política.

---

## 8. Comparando os três ambientes que construímos

- **lab/ (Docker):** aprendizado. Tudo numa máquina, sem HA real de etcd/HAProxy.
- **on-prem/ (este):** produção no seu hardware. Você opera tudo (e ganha controle total), com HA de verdade em etcd e HAProxy. Mais trabalho operacional: backup, upgrade, monitoramento são por sua conta.
- **terraform/ (Aurora/AWS):** produção gerenciada. A AWS opera o banco; menos controle, menos trabalho.

Todos os três são **replicação single-leader** (writer + réplicas de leitura). Nenhum deles escala *escrita* além de um nó — isso continua sendo assunto de **sharding**.
