import { DataSource } from 'typeorm';
import { writeDataSourceOptions } from './data-source-options';

/**
 * DataSource de ESCRITA exportado como default.
 *
 * Serve a dois propósitos:
 *  1) É o "-d" usado pela CLI do TypeORM nos scripts de migration
 *     (migration:run / migration:generate / migration:revert).
 *  2) Reaproveita as mesmas opções usadas pela aplicação em runtime.
 *
 * A CLI do TypeORM exige um DataSource exportado como default neste módulo.
 */
const writeDataSource = new DataSource(writeDataSourceOptions());
export default writeDataSource;
