# Nosso lab à luz do DDIA (capítulo 5: Replication)

Este documento amarra **tudo o que construímos no lab** com o vocabulário e os conceitos do capítulo de Replication do *Designing Data-Intensive Applications* (Martin Kleppmann). A ideia é você reler o capítulo e reconhecer cada conceito rodando de verdade nos seus containers.

---

## 1. O que montamos (relembrando)

```
                         ┌──────────────────────────┐
   aplicação ──────────► │          HAProxy         │
   ESCRITA  :5000 ─────► │  :5000  → PRIMÁRIO        │
   LEITURA  :5001 ─────► │  :5001  → RÉPLICAS (RR)   │
                         └─────────────┬────────────┘
              ┌───────────────┬────────┴──────┬───────────────┐
              ▼               ▼               ▼               ▼
           ┌──────┐        ┌──────┐        ┌──────┐        ┌──────┐
           │ pg1  │ ─WAL─► │ pg2  │        │ pg3  │        │ pg4  │
           │PRIMARY│        │REPLICA│       │REPLICA│       │REPLICA│
           └──┬───┘        └──────┘        └──────┘        └──────┘
              │ etcd (consenso: quem é o líder)
```

Ferramentas: PostgreSQL (o banco), Patroni (orquestra papéis e failover), etcd (consenso/estado), HAProxy (roteamento escrita/leitura).

---

## 2. O modelo: Single-Leader Replication

O DDIA abre o capítulo com três modelos de replicação. O nosso é o primeiro:

- **Single-leader (líder único)** ← **é o nosso lab**
- Multi-leader (múltiplos líderes)
- Leaderless (sem líder, estilo Dynamo/Cassandra)

No vocabulário do livro:

| DDIA | No nosso lab |
|------|--------------|
| **Leader** (ou master/primary) | `pg1` (ou quem for eleito) — único que aceita **escrita** |
| **Followers** (ou replicas/standbys) | os outros três nós — só **leitura** |
| **Replication log / change stream** | o **WAL** (Write-Ahead Log) do PostgreSQL |
| **Read scaling** | porta `:5001` do HAProxy distribuindo SELECTs entre followers |

A regra fundamental do single-leader (DDIA): **toda escrita passa pelo líder**; os followers aplicam, em ordem, o mesmo log de mudanças que o líder produziu. É literalmente o que o `:5000` (escrita no líder) e o streaming de WAL fazem.

---

## 3. Como a replicação acontece: o WAL como "replication log"

O DDIA descreve várias formas de implementar o log de replicação. O PostgreSQL (e o nosso lab) usa o equivalente ao **WAL shipping / streaming replication**:

- Toda mudança no líder é escrita primeiro no **WAL** (log append-only).
- Os followers recebem esse WAL via **streaming** e o **reaplicam** na mesma ordem, ficando réplicas byte-a-byte do líder.

Isso casa com a discussão do DDIA sobre **"WAL-based replication"**: a réplica reconstrói exatamente o mesmo estado do líder aplicando o log. A desvantagem que o livro aponta (acoplamento à versão do storage engine, dificultando upgrades) é real aqui: réplicas precisam ser da mesma versão major do Postgres.

---

## 4. Síncrono vs Assíncrono (o coração do capítulo)

O DDIA dedica boa parte do capítulo a este trade-off, e nós o vivemos diretamente.

**Nosso lab é assíncrono por padrão.** O líder confirma o commit para a aplicação **sem esperar** os followers confirmarem o recebimento do WAL.

- **Vantagem (DDIA):** escrita rápida; o líder não fica refém de uma réplica lenta.
- **Desvantagem (DDIA):** se o líder cai antes de propagar uma escrita confirmada, essa escrita **se perde**. É **durabilidade não garantida** no failover.

Isso não é teoria abstrata: é exatamente a ressalva que escrevemos no `FAILOVER.md` — a "escrita órfã" que só existia no líder morto é descartada quando ele volta via `pg_rewind`.

O livro também descreve **replicação semissíncrona**: pelo menos uma réplica é síncrona. É precisamente o que o `synchronous_mode: true` do Patroni faz (mostramos no `FAILOVER.md`): o commit só retorna após uma réplica confirmar o WAL. Trade-off do DDIA na prática: você **troca latência de escrita por garantia de não perder dado confirmado**.

---

## 5. Failover: o que o DDIA chama de "Handling Node Outages"

O DDIA divide falhas em duas:

### 5.1 Follower failure → "Catch-up recovery"
Um follower que cai e volta sabe a última posição do WAL que aplicou; ao reconectar, ele pede ao líder tudo a partir dali e se atualiza. No nosso lab isso é automático via streaming + **replication slots** (`use_slots: true`), que fazem o líder **segurar o WAL** que a réplica ainda não consumiu.

> Cuidado que documentamos no `ESCALANDO-REPLICAS.md`: esse mesmo slot pode **encher o disco do líder** se a réplica ficar muito tempo fora. O DDIA menciona o problema de o líder precisar reter o log para followers atrasados.

### 5.2 Leader failure → "Failover"
Aqui o DDIA lista os passos e os perigos, e o **Patroni + etcd** implementam exatamente isso:

| Passo do failover (DDIA) | Quem faz no lab |
|--------------------------|-----------------|
| 1. Detectar que o líder morreu | Patroni: a chave de liderança no **etcd** expira (TTL) |
| 2. Escolher novo líder | Patroni elege a réplica mais atualizada (`maximum_lag_on_failover`) |
| 3. Reconfigurar o sistema para usar o novo líder | HAProxy passa a rotear `:5000` para o novo primário (via health check `/primary`) |

E os **perigos do failover** que o DDIA enumera, todos presentes aqui:

- **Perda de dados (assíncrono):** escritas não propagadas somem. (nosso `pg_rewind` descarta a divergência)
- **Split-brain (dois líderes):** o pior cenário. É **exatamente por isso que existe o etcd**. O consenso garante que só um nó detém a "chave de líder" por vez. Sem um árbitro de consenso, dois nós poderiam achar que são líderes e aceitar escritas conflitantes.
- **Timeout mal calibrado:** o DDIA alerta que um timeout curto causa failovers desnecessários; um longo aumenta o downtime. São os nossos `ttl`/`loop_wait`/`retry_timeout` do Patroni — e foi por causa disso que ajustamos os tempos quando o etcd sofreu com I/O lento no boot.

> Detalhe importante de vocabulário: o **etcd** é uma peça de **consenso** (Raft). O DDIA conecta isso ao capítulo 9 (consistency & consensus). No nosso lab, o etcd é o "árbitro" que resolve o problema do single-leader: *quem* é o líder, de forma que todos concordem.

---

## 6. Problemas de Replication Lag (a parte mais famosa do capítulo)

Como somos **assíncronos**, sofremos os três problemas clássicos que o DDIA descreve — e eles aparecem assim que você lê de uma réplica logo após escrever no líder:

### 6.1 Read-your-writes consistency
Você escreve no `:5000` (líder) e imediatamente lê do `:5001` (réplica). Se a réplica ainda não recebeu o WAL, **você não vê o que acabou de escrever**.
- **Mitigação (DDIA + nosso lab):** leituras que precisam refletir a própria escrita devem ir ao **líder** (`:5000`).

### 6.2 Monotonic reads
Duas leituras seguidas caem em réplicas com lag diferente, e a segunda parece "andar para trás no tempo".
- **Mitigação:** amarrar o usuário sempre à mesma réplica (no nosso HAProxy seria afinar o balanceamento por sessão, em vez de round-robin puro).

### 6.3 Consistent prefix reads
Eventos causalmente ordenados aparecem fora de ordem. Mais crítico em sistemas **particionados** (cada partição replica independente). No nosso lab single-shard isso é menos visível, mas o DDIA já planta a semente para o assunto de sharding.

A lição central do livro, que vale gravar: **replicação assíncrona troca consistência por desempenho/disponibilidade.** Você escolhe onde, por requisito, "pagar" por consistência (lendo do líder) e onde tolerar lag (lendo de réplica).

---

## 7. O que a aplicação NestJS demonstra disso

O padrão de **dois DataSources** da `app-ha` é a materialização do single-leader no código:

- DataSource de **escrita** → `:5000` → **leader** (toda mutação)
- DataSource de **leitura** → `:5001` → **followers** (consultas tolerantes a lag)

O endpoint `/users/nodes` que criamos mostra, em tempo real, **qual nó** respondeu e se ele está em `recovery` (follower) — ou seja, você vê o single-leader e o read-scaling funcionando com os próprios olhos.

---

## 8. A fronteira do capítulo: replicação ≠ particionamento

O DDIA é explícito: **replicação** (cap. 5) e **particionamento/sharding** (cap. 6) resolvem problemas **diferentes**.

- **Replicação (o que fizemos):** mesma cópia dos dados em vários nós. Escala **leitura** e dá **disponibilidade/tolerância a falhas**. **Não** aumenta a capacidade de **escrita** — continua um único líder.
- **Particionamento (cap. seguinte):** divide os dados em pedaços distintos entre nós. É o que escala **escrita** e **volume**.

Tudo o que construímos — lab e o Terraform/Aurora — é **replicação single-leader**. O teto de escrita (um líder só) é o gancho natural para o próximo capítulo do livro: **sharding**.

---

## 9. Mapa rápido: conceito DDIA → ferramenta do lab

| Conceito (DDIA, cap. 5) | Onde está no nosso lab |
|-------------------------|------------------------|
| Single-leader replication | toda a arquitetura (1 primário + 3 réplicas) |
| Leader / Followers | primário Postgres / réplicas Postgres |
| Replication log | WAL do PostgreSQL (streaming replication) |
| Synchronous / Asynchronous | assíncrono por padrão; `synchronous_mode` do Patroni para semissíncrono |
| Catch-up recovery (follower) | streaming + replication slots (`use_slots`) |
| Failover (leader) | Patroni (detecção, eleição, promoção) |
| Evitar split-brain | etcd (consenso/Raft) |
| Timeouts de detecção | `ttl`, `loop_wait`, `retry_timeout` do Patroni |
| Read scaling | HAProxy `:5001` round-robin entre réplicas |
| Read-your-writes / Monotonic / Consistent prefix | efeitos de ler do `:5001` logo após escrever no `:5000` |
| Replicação ≠ Particionamento | nosso cluster escala leitura, não escrita → sharding é o próximo passo |
