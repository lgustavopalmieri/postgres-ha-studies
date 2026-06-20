import { DataSourceOptions } from 'typeorm';
import { User } from '../users/user.entity';

// Extrai do union DataSourceOptions apenas a variante do driver 'postgres'.
// Evita importar caminhos internos da typeorm (que não resolvem sob nodenext)
// e preserva o literal `type: 'postgres'` ao usar spread nas funções abaixo.
type PostgresOptions = Extract<DataSourceOptions, { type: 'postgres' }>;

/**
 * Opções COMPARTILHADAS entre as conexões de escrita e leitura.
 *
 * Pontos-chave do que foi pedido:
 *  - synchronize: false  -> o TypeORM NUNCA altera o schema sozinho.
 *                           Toda mudança de schema passa por MIGRATION.
 *  - migrations          -> apontamos para os arquivos de migration.
 *
 * Credenciais/host/porta vêm de variáveis de ambiente, para o mesmo código
 * rodar tanto localmente (localhost:5000/5001) quanto dentro do docker-compose
 * (haproxy:5000/5001).
 */
function baseOptions(): PostgresOptions {
    return {
        type: 'postgres',
        username: process.env.DB_USER ?? 'postgres',
        password: process.env.DB_PASSWORD ?? 'postgres_pwd',
        database: process.env.DB_NAME ?? 'postgres',
        entities: [User],
        // synchronize DESLIGADO de propósito: schema é versionado via migrations.
        synchronize: false,
        logging: ['error', 'schema', 'migration'],
    };
}

/**
 * Conexão de ESCRITA -> HAProxy :5000 (sempre o PRIMÁRIO).
 * É AQUI que as migrations rodam, pois só o primário aceita DDL/escrita.
 */
export function writeDataSourceOptions(): DataSourceOptions {
    return {
        ...baseOptions(),
        host: process.env.DB_WRITE_HOST ?? 'localhost',
        port: parseInt(process.env.DB_WRITE_PORT ?? '5000', 10),
        migrations: [__dirname + '/migrations/*.{ts,js}'],
        migrationsTableName: 'migrations_history',
    };
}

/**
 * Conexão de LEITURA -> HAProxy :5001 (RÉPLICAS, round-robin).
 * Não roda migrations e, na prática, só executa SELECT (as réplicas são
 * read-only; um INSERT aqui retornaria erro de "read-only transaction").
 */
export function readDataSourceOptions(): DataSourceOptions {
    return {
        ...baseOptions(),
        host: process.env.DB_READ_HOST ?? 'localhost',
        port: parseInt(process.env.DB_READ_PORT ?? '5001', 10),
    };
}
