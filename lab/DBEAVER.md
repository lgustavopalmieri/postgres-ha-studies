# Conexões do DBeaver

Crie uma conexão PostgreSQL para cada nó. Os dados de login são iguais em todos:

- Usuário: postgres
- Senha: postgres_pwd
- Database: postgres

## pg1
- Host: localhost
- Porta: 5432

## pg2
- Host: localhost
- Porta: 5433

## pg3
- Host: localhost
- Porta: 5434

## pg4
- Host: localhost
- Porta: 5435

## Dica

Você não sabe de antemão qual nó é o primário (ele é eleito em tempo de execução). Para descobrir, rode em qualquer conexão:

SELECT pg_is_in_recovery();

- false = primário (aceita escrita)
- true = réplica (somente leitura)
