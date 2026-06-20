# Imagem base oficial do PostgreSQL 16 (Debian Bookworm).
# Em cima dela instalamos o Patroni, que é quem vai controlar o ciclo de vida
# do Postgres (initdb, promover/rebaixar nó, replicação, failover...).
FROM postgres:16

# Dependências:
# - python3 / pip       -> o Patroni é escrito em Python
# - libpq-dev / gcc     -> para compilar dependências nativas (psycopg2)
# - curl                -> útil para healthcheck/debug da REST API do Patroni
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        python3 \
        python3-pip \
        python3-dev \
        libpq-dev \
        gcc \
        curl \
    && pip3 install --break-system-packages --no-cache-dir \
        psycopg2-binary \
        "patroni[etcd3]" \
    && apt-get purge -y --auto-remove gcc python3-dev \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# O patroni.yml NÃO é copiado: ele é gerado em tempo de execução pelo
# entrypoint, pois cada nó precisa do próprio nome/IP. Só criamos a pasta.
RUN mkdir -p /etc/patroni
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Porta do Postgres e porta da REST API do Patroni (usada pelo HAProxy nos health checks)
EXPOSE 5432 8008

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
