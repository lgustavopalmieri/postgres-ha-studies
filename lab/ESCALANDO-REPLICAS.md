# Adicionando réplicas de leitura "com o carro andando"

Como crescer a capacidade de leitura do cluster sem downtime, e os perigos reais de fazer isso em produção.

A arquitetura (Patroni + etcd + HAProxy) já foi feita para isso: adicionar réplica é uma das operações mais tranquilas num cluster Patroni. O risco não está no "adicionar" em si, mas em **de onde você clona**, **monitorar o WAL/slot** e **evitar que um nó atrasado vire primário**.

---

## 1. O que acontece quando uma réplica nova entra

Um novo nó sobe com a MESMA configuração dos outros (mesmo `scope`, apontando para o mesmo etcd). O Patroni então:

1. Consulta o etcd e vê que **já existe um líder** — logo, não tenta eleição.
2. Faz um **`pg_basebackup`**: clona o banco inteiro a partir do primário (ou de outra réplica).
3. Conecta no **streaming de WAL** e aplica tudo o que mudou desde o início do clone (catch-up).
4. Quando alcança o líder, o health check `/replica` do Patroni passa a responder 200.
5. O **HAProxy** detecta isso e começa a rotear leitura (porta 5001) para o novo nó.

Nada para. As escritas continuam no primário, as leituras continuam sendo servidas pelas réplicas existentes durante todo o processo.

---

## 2. Fazendo na prática NESTE cluster (Docker)

### Passo 2.1 - Adicionar o serviço `pg5` no `docker-compose.yml`

É só copiar um bloco existente e trocar nome/porta:

```yaml
  pg5:
    build: ./patroni
    hostname: pg5
    container_name: pg5
    networks: [pgnet]
    restart: unless-stopped
    ports:
      - "5436:5432"   # acesso direto (DBeaver) -> localhost:5436
    volumes:
      - pg5_data:/var/lib/postgresql/data
    depends_on:
      etcd:
        condition: service_healthy
```

E declarar o volume novo na seção `volumes:` no fim do arquivo:

```yaml
volumes:
  pg1_data:
  pg2_data:
  pg3_data:
  pg4_data:
  pg5_data:
```

### Passo 2.2 - Adicionar o nó no `haproxy/haproxy.cfg`

Em AMBOS os blocos (`postgres_write` e `postgres_read`), adicione a linha do novo nó:

```
    server pg5 pg5:5432 maxconn 100 check port 8008
```

> Observação: pode adicionar nos dois blocos sem medo. Como o roteamento é decidido pelo health check (`/primary` x `/replica`), o pg5 só vai receber leitura enquanto for réplica.

### Passo 2.3 - Subir só o nó novo (sem tocar no resto)

```bash
docker compose up -d pg5
```

### Passo 2.4 - Recarregar o HAProxy para enxergar o novo backend

```bash
docker compose restart haproxy
```

### Passo 2.5 - Acompanhar a entrada do nó

```bash
# Ver o pg5 clonando / entrando como réplica
docker compose logs -f pg5

# Ver o estado do cluster (pg5 deve aparecer como Replica)
docker compose exec pg1 patronictl -c /etc/patroni/patroni.yml list
```

Saída esperada (note o pg5 no fim, com lag indo para 0):

```
+ Cluster: pg-cluster --+---------+---------+----+-----------+
| Member | Host  | Role    | State   | TL | Lag in MB |
+--------+-------+---------+---------+----+-----------+
| pg1    | ...   | Leader  | running |  1 |           |
| pg2    | ...   | Replica | running |  1 |         0 |
| ...    | ...   | ...     | ...     |    |           |
| pg5    | ...   | Replica | running |  1 |         0 |
+--------+-------+---------+---------+----+-----------+
```

Quando `State = running` e `Lag in MB = 0`, o pg5 já está servindo leitura pelo HAProxy. **A aplicação não precisa de nenhuma mudança** — ela continua usando a porta 5001 e o HAProxy passa a incluir o pg5 no rodízio.

---

## 3. Os trade-offs e perigos reais (produção)

Em produção os nós não são containers efêmeros, mas o fluxo conceitual é o mesmo. Os pontos de atenção abaixo são o que realmente importa.

### 3.1 - O basebackup pesa no nó de origem

Clonar um banco de, por exemplo, 500GB significa ler 500GB e jogá-los na rede. Se o novo nó clonar **direto do primário**, você rouba I/O e banda de quem está atendendo produção, podendo degradar a latência das escritas.

**Mitigação: clonar de uma réplica, não do primário.** No Patroni, marque uma réplica como fonte de clone preferencial, usando a tag `clonefrom`:

```yaml
# no patroni.yml da réplica que servirá de fonte
tags:
  clonefrom: true
```

Para bancos grandes, o ideal é usar uma ferramenta de backup como método de bootstrap (ex.: `pgBackRest`), restaurando o novo nó a partir do backup em vez de tocar no primário:

```yaml
# exemplo de bootstrap method no patroni.yml (conceitual)
bootstrap:
  method: pgbackrest
  pgbackrest:
    command: pgbackrest --stanza=main --delta restore
    keep_existing_recovery_conf: true
```

### 3.2 - Replication slots podem encher o disco do primário

Com `use_slots: true` (que este cluster usa), o primário **segura o WAL** que uma réplica ainda não consumiu. Se o novo nó demora para clonar ou trava no meio, o primário acumula WAL e, no pior caso, **enche o próprio disco** — o que pode derrubar o primário. Esse é o perigo mais subestimado.

**Monitore os slots e o atraso de cada um:**

```sql
-- Quanto WAL cada slot está segurando (rode no primário)
SELECT
  slot_name,
  active,
  pg_size_pretty(
    pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)
  ) AS retained_wal
FROM pg_replication_slots
ORDER BY retained_wal DESC;
```

Em produção: alarme de espaço em disco no primário + alarme se `retained_wal` de algum slot crescer demais. Como rede de segurança, o Postgres tem `max_slot_wal_keep_size` (limita o WAL retido por slot, ao custo de invalidar o slot se estourar).

### 3.3 - Janela de catch-up

Enquanto o novo nó aplica o WAL acumulado para alcançar o líder, ele consome CPU/I/O e ainda **não serve leitura útil**. Em bancos com escrita intensa, o catch-up pode demorar — e, se a taxa de escrita for maior que a de aplicação, o nó pode "nunca alcançar".

**Acompanhe o lag até zerar:**

```sql
-- Rode na réplica nova: diferença entre o que recebeu e o que aplicou
SELECT
  pg_size_pretty(
    pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn())
  ) AS replay_lag;
```

### 3.4 - Não deixe um nó atrasado virar primário

Um nó ainda clonando/atrasado não deve ser elegível a líder. Duas proteções:

- `maximum_lag_on_failover` (já configurado) impede promover um nó com lag acima do limite.
- Para ser conservador, suba o nó novo com `nofailover: true` e remova a tag só depois que ele estiver em dia:

```yaml
tags:
  nofailover: true   # não pode ser promovido enquanto está entrando
```

Aplicar/retirar em runtime:

```bash
docker compose exec pg5 patronictl -c /etc/patroni/patroni.yml edit-config
```

### 3.5 - Réplica de Postgres é seguro; membro de etcd exige cuidado

Adicionar **réplicas Postgres** NÃO mexe no etcd. Mas se for crescer o **cluster etcd** em produção, há regra de quórum: sempre número **ímpar** de membros (3, 5, 7) e adição "com o carro andando" é bem mais delicada (envolve `member add` e risco de perder quórum se feito errado). Resumo: escalar leitura Postgres = rotina; mexer no etcd = operação sensível.

### 3.6 - Cache frio ao entrar no rodízio

Assim que o health check `/replica` passa, o HAProxy manda leitura para o nó novo — que ainda tem **caches frios**. Os primeiros SELECTs podem vir mais lentos. Não é grave, mas em sistemas sensíveis a latência, considere "aquecer" o nó (rodar queries representativas) antes de expô-lo, ou usar `pg_prewarm`.

---

## 4. Resumo prático

- Adicionar réplica de leitura é **operação rotineira e de baixo risco** no Patroni.
- Os perigos não estão no "adicionar", e sim em:
  - **De onde clonar:** não sufoque o primário — clone de réplica ou de backup em bancos grandes.
  - **Monitorar slot/WAL:** evite encher o disco do primário.
  - **Evitar promoção indevida:** garanta que o nó atrasado não vire primário no meio do caminho.
- Com banco grande, a regra de ouro: bootstrap a partir de backup (pgBackRest) ou de réplica, **nunca do primário em horário de pico**.