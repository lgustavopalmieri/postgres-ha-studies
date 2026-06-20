# PostgreSQL HA: 1 escrita + 3 leituras (Patroni + etcd + HAProxy)

Ambiente de estudo em Docker com **um primário (escrita)** e **três réplicas (leitura)**, com **failover automático**. O objetivo aqui é você entender *como* a replicação funciona e *como sua aplicação consome* esse cluster.

## A arquitetura em uma imagem mental

```
                          ┌──────────────────────────┐
   sua aplicação ───────► │          HAProxy         │
                          │                          │
   ESCRITA  :5000 ──────► │  :5000  → PRIMÁRIO        │
   LEITURA  :5001 ──────► │  :5001  → RÉPLICAS (RR)   │
                          └─────────────┬────────────┘
                                        │ (health checks na REST API do Patroni :8008)
              ┌───────────────┬─────────┴───────┬───────────────┐
              ▼               ▼                 ▼               ▼
           ┌──────┐        ┌──────┐          ┌──────┐        ┌──────┐
           │ pg1  │        │ pg2  │          │ pg3  │        │ pg4  │
           │PRIMÁRIO│ ───► │RÉPLICA│ ───►    │RÉPLICA│ ───►   │RÉPLICA│
           └──┬───┘  WAL   └──────┘   WAL    └──────┘  WAL    └──────┘
              │  streaming replication (o primário envia o WAL para as réplicas)
              │
           ┌──┴───┐
           │ etcd │  guarda "quem é o líder" e a config do cluster
           └──────┘
```

### Quem é quem
- **PostgreSQL (pg1..pg4):** os bancos. Um é primário (aceita escrita), os outros replicam e servem leitura.
- **Patroni:** o "cérebro" em cada nó. Inicia o Postgres, configura replicação, monitora saúde e faz **failover automático** (promove uma réplica se o primário morrer).
- **etcd:** onde os nós registram e consultam **quem é o líder**. É o que evita "dois primários" (split-brain).
- **HAProxy:** o endereço único da aplicação. Roteia escrita para o primário e leitura para as réplicas, consultando o Patroni para saber quem é quem.

> Decisão importante: o papel primário/réplica **não é fixo** no compose. Quem decide é a eleição via etcd. Por isso o failover funciona sem você mexer em nada.

## Como subir

```bash
docker compose up -d --build
```

Aguarde ~30-60s no primeiro boot (initdb no primário + clone das réplicas). Acompanhe:

```bash
docker compose logs -f pg1 pg2 pg3 pg4
```

## Como ver o estado do cluster

O Patroni tem uma CLI ótima pra isso (`patronictl`). Rode dentro de qualquer nó:

```bash
docker compose exec pg1 patronictl -c /etc/patroni/patroni.yml list
```

Saída esperada (um Leader + 3 Replicas):

```
+ Cluster: pg-cluster ------+---------+---------+----+-----------+
| Member | Host      | Role    | State   | TL | Lag in MB |
+--------+-----------+---------+---------+----+-----------+
| pg1    | 10.x.x.x  | Leader  | running |  1 |           |
| pg2    | 10.x.x.x  | Replica | running |  1 |         0 |
| pg3    | 10.x.x.x  | Replica | running |  1 |         0 |
| pg4    | 10.x.x.x  | Replica | running |  1 |         0 |
+--------+-----------+---------+---------+----+-----------+
```

Você também pode abrir o painel do HAProxy em **http://localhost:7000** (admin/admin) para ver quais backends estão UP em cada porta.

## Como sua aplicação se conecta (o ponto central)

A regra de ouro: **escrita numa porta, leitura em outra.**

| Operação | Host | Porta | Vai para |
|----------|------|-------|----------|
| INSERT / UPDATE / DELETE / DDL | localhost | **5000** | primário |
| SELECT (consultas) | localhost | **5001** | réplicas (round-robin) |

Usuário/senha do exemplo: `postgres` / `postgres_pwd`.

### Teste rápido pelo terminal

Escrever (porta 5000):
```bash
docker compose exec pg1 psql "postgresql://postgres:postgres_pwd@haproxy:5000/postgres" \
  -c "CREATE TABLE IF NOT EXISTS produtos(id serial primary key, nome text);" \
  -c "INSERT INTO produtos(nome) VALUES ('teclado'),('mouse');"
```

Ler (porta 5001 — bate numa réplica):
```bash
docker compose exec pg1 psql "postgresql://postgres:postgres_pwd@haproxy:5001/postgres" \
  -c "SELECT * FROM produtos;"
```

Se a leitura retornou os dados que você acabou de inserir, a **replicação está funcionando** (o WAL foi do primário para a réplica).

Provando que a 5001 é só-leitura (deve dar erro `cannot execute INSERT in a read-only transaction`):
```bash
docker compose exec pg1 psql "postgresql://postgres:postgres_pwd@haproxy:5001/postgres" \
  -c "INSERT INTO produtos(nome) VALUES ('isso vai falhar');"
```

## Testando o failover (a parte divertida)

1. Veja quem é o líder: `docker compose exec pg1 patronictl -c /etc/patroni/patroni.yml list`
2. Mate o líder (suponha que seja o pg1): `docker compose stop pg1`
3. Espere ~10-30s e liste de novo (rode de outro nó): 
   ```bash
   docker compose exec pg2 patronictl -c /etc/patroni/patroni.yml list
   ```
   Uma das réplicas agora aparece como **Leader**.
4. A porta de escrita 5000 do HAProxy **continua funcionando**, agora apontando para o novo primário — sua aplicação nem percebe (além de reconectar).
5. Religue o nó antigo: `docker compose start pg1`. Ele volta como **réplica** do novo líder (o Patroni usa `pg_rewind` para reintegrá-lo).

## A aplicação NestJS (`app-ha/`)

Uma API NestJS demonstra o padrão na prática. Ela mantém **dois `DataSource` do TypeORM**: um para escrita (HAProxy :5000) e outro para leitura (:5001). O schema é versionado por **migration** (`synchronize` está desligado), e a migration roda **no boot da aplicação** pela conexão de escrita (primário).

### Endpoints

A API tem **Swagger UI** em **http://localhost:3000/docs** — é por ali que você testa tudo (botão "Try it out").

| Método | Rota | Vai para | O que faz |
|--------|------|----------|-----------|
| `POST` | `/users` | escrita (:5000) | cria usuário (`{ "name": "...", "email": "..." }`) |
| `GET` | `/users` | leitura (:5001) | lista usuários |
| `GET` | `/users/:id` | leitura (:5001) | busca um usuário |
| `GET` | `/users/nodes` | ambas | diagnóstico: mostra o IP do nó e se é réplica em cada conexão |

### Rodando junto do cluster (Docker)

A API já está no `docker-compose.yml` como serviço `api`. Após `docker compose up -d --build`, acesse em **http://localhost:3000**.

```bash
# cria um usuário (escrita -> primário)
curl -X POST http://localhost:3000/users \
  -H 'Content-Type: application/json' \
  -d '{"name":"Ana","email":"ana@example.com"}'

# lista (leitura -> réplica)
curl http://localhost:3000/users

# veja em qual nó cada conexão caiu
curl http://localhost:3000/users/nodes
```

No `/users/nodes`, o esperado é `write.is_replica = false` (primário) e `read.is_replica = true` (réplica). É a separação leitura/escrita visível.

### Rodando a API localmente (fora do Docker)

Com o cluster no ar (HAProxy expondo 5000/5001 no host):

```bash
cd app-ha
npm install
npm run start:dev
```

As portas/credenciais têm default para `localhost:5000`/`localhost:5001`, mas podem ser sobrescritas por variáveis de ambiente (`DB_WRITE_HOST`, `DB_WRITE_PORT`, `DB_READ_HOST`, `DB_READ_PORT`, `DB_USER`, `DB_PASSWORD`, `DB_NAME`).

### Sobre as migrations

- `synchronize: false` — o TypeORM nunca altera o schema sozinho.
- No boot, o `DatabaseModule` chama `runMigrations()` na conexão de escrita; as migrations aplicadas ficam registradas na tabela `migrations_history`.
- Comandos manuais (com o cluster no ar): `npm run migration:run`, `npm run migration:revert`, `npm run migration:generate -- src/database/migrations/NomeDaMigration`.

### Cuidado conceitual: replication lag
A replicação é **assíncrona** por padrão. Existe um pequeno atraso entre escrever no primário e o dado aparecer na réplica. Na prática: se você escreve e *imediatamente* lê de uma réplica, pode não ver o dado ainda ("read-your-writes" não garantido). Estratégias comuns:
- Para fluxos que exigem ler o que acabou de escrever, leia do **primário** (5000).
- Use replicação **síncrona** se precisar de garantia forte (custa latência de escrita).

## Para derrubar tudo

```bash
docker compose down          # para os containers
docker compose down -v       # para e APAGA os dados (volumes)
```

## Estrutura do projeto

```
.
├── docker-compose.yml      # orquestra etcd, 4 postgres, haproxy e a api
├── patroni/
│   ├── Dockerfile          # postgres:16 + patroni
│   └── entrypoint.sh       # gera o patroni.yml por nó e sobe o patroni
├── haproxy/
│   └── haproxy.cfg         # roteamento escrita(5000)/leitura(5001)
└── app-ha/                 # API NestJS (TypeORM, 2 datasources, migrations)
    └── src/
        ├── database/       # datasources, módulo e migrations
        └── users/          # entidade, service e controller
```
