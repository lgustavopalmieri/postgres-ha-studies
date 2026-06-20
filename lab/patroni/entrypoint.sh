#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Este entrypoint gera o patroni.yml em tempo de execução para cada container.
#
# Por que gerar dinamicamente? Porque cada nó do cluster precisa de um NOME
# único e de saber o próprio endereço de rede. Usamos o hostname do container
# (que no docker-compose é o nome do serviço, ex.: pg1, pg2, pg3, pg4).
#
# Todos os nós sobem com a MESMA imagem e o MESMO entrypoint. Quem define o
# papel (primário x réplica) NÃO é o nosso script: é o Patroni + etcd, em
# tempo de execução, via eleição de líder. O primeiro nó a "pegar a chave" no
# etcd vira líder/primário; os demais entram como réplicas e começam a
# replicar a partir dele.
# -----------------------------------------------------------------------------

# Nome do nó = hostname do container (pg1, pg2, ...). Único dentro da rede.
NODE_NAME="$(hostname)"

# IP do container na rede do compose. O Patroni anuncia esse IP no etcd para
# que os outros nós saibam como se conectar a este.
NODE_IP="$(hostname -i | awk '{print $1}')"

# Diretório de dados do Postgres. É gerenciado pelo Patroni (ele roda o initdb
# na primeira vez no líder, e o pg_basebackup nas réplicas).
export PGDATA="${PGDATA:-/var/lib/postgresql/data/pgdata}"

cat > /etc/patroni/patroni.yml <<EOF
# ============================================================================
# CONFIGURAÇÃO DO PATRONI PARA O NÓ: ${NODE_NAME}
# ============================================================================

# scope = nome do cluster. TODOS os nós precisam do MESMO scope para se
# enxergarem no etcd e formarem um único cluster.
scope: pg-cluster
# name = identificador único deste nó dentro do cluster.
name: ${NODE_NAME}

# --- REST API do Patroni -----------------------------------------------------
# O Patroni expõe uma API HTTP (porta 8008). O HAProxy usa essa API para
# descobrir QUEM é o primário e QUEM são réplicas saudáveis:
#   GET /primary  -> responde 200 só se ESTE nó for o primário
#   GET /replica  -> responde 200 só se ESTE nó for uma réplica saudável
restapi:
  listen: 0.0.0.0:8008
  connect_address: ${NODE_IP}:8008

# --- Conexão com o etcd (DCS - Distributed Configuration Store) --------------
# É aqui que os nós "votam" e guardam o estado do cluster (quem é líder, etc).
etcd3:
  hosts:
    - etcd:2379

# --- Bootstrap: usado APENAS na primeira inicialização do cluster ------------
# Define como o cluster nasce. Só o PRIMEIRO nó (que ganha a eleição) executa
# este bloco. Os demais ignoram e fazem clone do líder.
bootstrap:
  dcs:
    ttl: 30                  # tempo (s) que o líder tem para renovar a "chave" de liderança
    loop_wait: 10            # de quanto em quanto tempo o Patroni roda seu loop de controle
    retry_timeout: 30        # timeout p/ operações no etcd/postgres (alto p/ tolerar picos de I/O no boot)
    maximum_lag_on_failover: 1048576  # lag máx (bytes) que uma réplica pode ter para ser elegível a líder
    postgresql:
      use_pg_rewind: true    # acelera reintegração de um ex-primário sem precisar de basebackup completo
      use_slots: true        # usa replication slots: o primário não descarta WAL que as réplicas ainda não consumiram
      parameters:
        # Parâmetros aplicados a TODO o cluster (ficam no DCS e são propagados):
        max_connections: 200
        max_wal_senders: 10        # nº de conexões de replicação que o primário aceita
        max_replication_slots: 10
        wal_level: replica         # nível de WAL necessário para replicação por streaming
        hot_standby: "on"          # permite LEITURA nas réplicas enquanto elas aplicam o WAL
        wal_keep_size: 128MB
  # initdb: opções da criação inicial do banco (roda só no primeiro nó)
  initdb:
    - encoding: UTF8
    - data-checksums

  # pg_hba: regras de autenticação. Aqui liberamos a rede interna do docker.
  # Em produção você restringiria os CIDRs e usaria senhas/SSL fortes.
  pg_hba:
    - host replication replicator 0.0.0.0/0 scram-sha-256
    - host all all 0.0.0.0/0 scram-sha-256

# --- Configuração local do Postgres neste nó ---------------------------------
postgresql:
  listen: 0.0.0.0:5432
  connect_address: ${NODE_IP}:5432
  data_dir: ${PGDATA}
  bin_dir: /usr/lib/postgresql/16/bin
  pgpass: /tmp/pgpass

  # Usuários que o Patroni cria/gerencia automaticamente:
  authentication:
    # 'replicator' é o usuário que as RÉPLICAS usam para puxar o WAL do primário.
    replication:
      username: replicator
      password: replicator_pwd
    # 'superuser' é o postgres admin usado pelo próprio Patroni para operar o nó.
    superuser:
      username: postgres
      password: postgres_pwd

  parameters:
    # unix_socket_directories: onde o Postgres cria o socket local.
    unix_socket_directories: '/var/run/postgresql'

# tags: ajustam o comportamento deste nó específico.
tags:
  nofailover: false      # este nó PODE virar primário
  noloadbalance: false   # este nó PODE receber tráfego de leitura
  clonefrom: false
  nosync: false
EOF

echo "[entrypoint] patroni.yml gerado para o nó '${NODE_NAME}' (IP ${NODE_IP})."

# O diretório de dados precisa pertencer ao usuário 'postgres' e ter permissão
# restrita (o Postgres recusa iniciar se o PGDATA estiver com permissões abertas).
mkdir -p "${PGDATA}"
chown -R postgres:postgres "$(dirname "${PGDATA}")"
chmod 700 "${PGDATA}" || true

# Rodamos o Patroni como usuário 'postgres' (nunca como root).
# É o Patroni — e não o entrypoint do Postgres — que vai iniciar o banco.
exec gosu postgres patroni /etc/patroni/patroni.yml
