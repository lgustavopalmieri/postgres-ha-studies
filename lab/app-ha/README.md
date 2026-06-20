# API de exemplo - PostgreSQL HA

API NestJS que demonstra separação leitura/escrita: escrita vai para o primário, leitura vai para as réplicas.

## Swagger

Com tudo no ar (`docker compose up -d --build`), teste os endpoints pela interface:

http://localhost:3000/docs

## Endpoints e payloads de exemplo

### POST /users (escrita -> primário)

Corpo da requisição:

```json
{
  "name": "Ana Silva",
  "email": "ana@example.com"
}
```

Resposta:

```json
{
  "id": 1,
  "name": "Ana Silva",
  "email": "ana@example.com",
  "createdAt": "2026-06-20T12:00:00.000Z"
}
```

### GET /users (leitura -> réplica)

Resposta:

```json
[
  {
    "id": 1,
    "name": "Ana Silva",
    "email": "ana@example.com",
    "createdAt": "2026-06-20T12:00:00.000Z"
  }
]
```

### GET /users/:id (leitura -> réplica)

Resposta:

```json
{
  "id": 1,
  "name": "Ana Silva",
  "email": "ana@example.com",
  "createdAt": "2026-06-20T12:00:00.000Z"
}
```

### GET /users/nodes (diagnóstico)

Mostra em qual nó cada conexão caiu. O esperado é a escrita no primário (`is_replica: false`) e a leitura numa réplica (`is_replica: true`).

```json
{
  "write": { "ip": "10.x.x.x", "is_replica": false },
  "read": { "ip": "10.x.x.x", "is_replica": true }
}
```
