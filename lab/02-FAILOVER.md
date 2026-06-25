# Failover e reintegração: como funciona

## Quando o master cai

O Patroni detecta a queda: a chave de liderança no etcd expira, porque o master morto para de renová-la. As réplicas percebem que o líder sumiu e disputam a eleição. O Patroni escolhe a réplica mais "em dia" (a com menor lag, dentro do `maximum_lag_on_failover` configurado) e a **promove a primário**.

A partir daí, as demais réplicas passam a seguir esse novo primário e recebem o WAL dele. A porta de escrita no HAProxy (5000) automaticamente passa a apontar para o novo líder.

## Quando o master antigo volta

Ele se reintegra **sozinho como réplica** e se atualiza. Mas o "como" tem uma sutileza importante.

O problema é que o ex-master pode ter um histórico **divergente**. Imagine: ele aceitou uma escrita, gravou no WAL local, mas caiu antes de enviar para qualquer réplica. Quando volta, ele tem um dado que o novo primário nunca viu. Agora as duas linhas do tempo (timelines) divergiram. Ele não pode simplesmente "continuar de onde parou", porque a verdade agora é a do novo primário.

É aí que entra o **`pg_rewind`**, habilitado com `use_pg_rewind: true` na config do Patroni. Ele faz o seguinte:

1. Identifica o ponto exato onde as timelines divergiram.
2. **Rebobina** o ex-master, desfazendo as mudanças locais que o novo primário não tem.
3. Sincroniza o ex-master a partir do novo primário daquele ponto em diante, via streaming do WAL.

Resultado: o ex-master vira réplica e fica idêntico ao novo primário, sem precisar copiar o banco inteiro do zero (que seria o `pg_basebackup`, bem mais lento). O Patroni orquestra tudo isso automaticamente.

## A ressalva importante

Aquela escrita "órfã" (que só existia no master morto) é **perdida** nesse processo. Isso é inerente à replicação **assíncrona**: existe uma janela de dados não confirmados que pode sumir num failover.

Se você não pode perder nenhuma transação confirmada, a solução é replicação **síncrona** (o primário só confirma o commit depois que pelo menos uma réplica recebeu o WAL), ao custo de mais latência na escrita. A configuração atual é assíncrona.

Resumindo:
- Failover automático: sim.
- Reintegração automática como réplica: sim (via `pg_rewind`).
- Atualização dos dados perdidos: sim, com a ressalva de que transações não replicadas no instante da queda podem ser descartadas.

---

# Como mudar para replicação síncrona

Hoje a replicação é assíncrona. Para torná-la síncrona, ajuste o bloco `bootstrap.dcs` no `patroni/entrypoint.sh` (a parte que gera o `patroni.yml`).

## 1. Ligar o modo síncrono no Patroni

Adicione, dentro de `bootstrap.dcs`:

```yaml
bootstrap:
  dcs:
    synchronous_mode: true
    # opcional: garante que NUNCA se faça failover para uma réplica que não
    # estava sincronizada (prioriza consistência sobre disponibilidade).
    synchronous_mode_strict: false
```

Com `synchronous_mode: true`, o Patroni gerencia automaticamente o parâmetro `synchronous_standby_names` do Postgres, elegendo uma réplica como síncrona e mantendo as outras como assíncronas.

## 2. (Opcional) Exigir mais de uma réplica síncrona

Por padrão, o modo síncrono espera a confirmação de **uma** réplica. Para exigir mais, use:

```yaml
bootstrap:
  dcs:
    synchronous_mode: true
    synchronous_node_count: 2   # commit só confirma após 2 réplicas receberem o WAL
```

## O trade-off

- **Garantia:** uma transação confirmada (commit que retornou OK) está garantidamente em pelo menos uma réplica. Nenhum dado confirmado se perde no failover.
- **Custo:** cada escrita espera a confirmação de uma réplica antes de retornar, o que aumenta a latência. Se a réplica síncrona ficar indisponível e `synchronous_mode_strict` estiver ligado, escritas podem bloquear até haver uma réplica síncrona saudável.

## Aplicando

Como mudamos o bloco `bootstrap` (que só vale na criação do cluster), o jeito mais simples em ambiente de estudo é recriar do zero:

```bash
docker compose down -v
docker compose up -d --build
```

Em um cluster já existente, o mesmo efeito é obtido em runtime sem recriar, via:

```bash
docker compose exec pg1 patronictl -c /etc/patroni/patroni.yml edit-config
```

e adicionando `synchronous_mode: true` na configuração que abrir.
