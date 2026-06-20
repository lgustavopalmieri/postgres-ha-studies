import { Global, Logger, Module } from '@nestjs/common';
import { DataSource } from 'typeorm';
import {
    readDataSourceOptions,
    writeDataSourceOptions,
} from './data-source-options';

/**
 * Tokens de injeção para diferenciar as duas conexões.
 * Em qualquer service você injeta uma delas com @Inject(WRITE_DATA_SOURCE)
 * ou @Inject(READ_DATA_SOURCE).
 */
export const WRITE_DATA_SOURCE = 'WRITE_DATA_SOURCE';
export const READ_DATA_SOURCE = 'READ_DATA_SOURCE';

/**
 * Provider da conexão de ESCRITA.
 * Ao inicializar, ele:
 *   1) conecta no primário (via HAProxy :5000);
 *   2) RODA AS MIGRATIONS PENDENTES (dataSource.runMigrations()).
 * É exatamente o "ver a migration rodando no boot" que foi pedido.
 */
const writeProvider = {
    provide: WRITE_DATA_SOURCE,
    useFactory: async (): Promise<DataSource> => {
        const logger = new Logger('WriteDataSource');
        const dataSource = new DataSource(writeDataSourceOptions());
        await dataSource.initialize();
        logger.log('Conexão de ESCRITA estabelecida (HAProxy :5000 -> primário).');

        const executed = await dataSource.runMigrations();
        if (executed.length > 0) {
            logger.log(
                `Migrations aplicadas: ${executed.map((m) => m.name).join(', ')}`,
            );
        } else {
            logger.log('Nenhuma migration pendente. Schema já está atualizado.');
        }
        return dataSource;
    },
};

/**
 * Provider da conexão de LEITURA.
 * Apenas conecta nas réplicas (via HAProxy :5001). Não roda migrations.
 */
const readProvider = {
    provide: READ_DATA_SOURCE,
    useFactory: async (): Promise<DataSource> => {
        const logger = new Logger('ReadDataSource');
        const dataSource = new DataSource(readDataSourceOptions());
        await dataSource.initialize();
        logger.log('Conexão de LEITURA estabelecida (HAProxy :5001 -> réplicas).');
        return dataSource;
    },
};

@Global()
@Module({
    providers: [writeProvider, readProvider],
    exports: [WRITE_DATA_SOURCE, READ_DATA_SOURCE],
})
export class DatabaseModule { }
