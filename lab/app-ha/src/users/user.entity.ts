import { ApiProperty } from '@nestjs/swagger';
import {
    Column,
    CreateDateColumn,
    Entity,
    PrimaryGeneratedColumn,
} from 'typeorm';

/**
 * Entidade simples de usuário.
 * O mapeamento das colunas casa com o que a migration CreateUsers cria.
 * Lembre: NÃO é o synchronize que cria essa tabela — é a migration.
 * Os @ApiProperty documentam o formato das respostas no Swagger.
 */
@Entity('users')
export class User {
    @ApiProperty({ example: 1 })
    @PrimaryGeneratedColumn()
    id: number;

    @ApiProperty({ example: 'Ana Silva' })
    @Column({ type: 'varchar', length: 120 })
    name: string;

    @ApiProperty({ example: 'ana@example.com' })
    @Column({ type: 'varchar', length: 180, unique: true })
    email: string;

    @ApiProperty({ example: '2026-06-20T12:00:00.000Z' })
    @CreateDateColumn({ name: 'created_at', type: 'timestamptz' })
    createdAt: Date;
}
