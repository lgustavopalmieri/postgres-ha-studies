import { MigrationInterface, QueryRunner, Table } from 'typeorm';

/**
 * Migration que cria a tabela `users`.
 *
 * Como synchronize está DESLIGADO, é esta migration (e não o TypeORM
 * automaticamente) que cria o schema. Ela roda no boot da aplicação,
 * através da conexão de ESCRITA (primário) — veja DatabaseModule.
 *
 * O nome do arquivo começa com um timestamp: é assim que o TypeORM ordena e
 * controla quais migrations já foram aplicadas (tabela `migrations_history`).
 */
export class CreateUsers1700000000000 implements MigrationInterface {
    name = 'CreateUsers1700000000000';

    public async up(queryRunner: QueryRunner): Promise<void> {
        await queryRunner.createTable(
            new Table({
                name: 'users',
                columns: [
                    { name: 'id', type: 'serial', isPrimary: true },
                    { name: 'name', type: 'varchar', length: '120', isNullable: false },
                    {
                        name: 'email',
                        type: 'varchar',
                        length: '180',
                        isNullable: false,
                        isUnique: true,
                    },
                    {
                        name: 'created_at',
                        type: 'timestamptz',
                        default: 'now()',
                        isNullable: false,
                    },
                ],
            }),
            true,
        );
    }

    public async down(queryRunner: QueryRunner): Promise<void> {
        await queryRunner.dropTable('users');
    }
}
