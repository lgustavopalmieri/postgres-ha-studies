import { Inject, Injectable } from '@nestjs/common';
import { DataSource, Repository } from 'typeorm';
import {
    READ_DATA_SOURCE,
    WRITE_DATA_SOURCE,
} from '../database/database.module';
import { User } from './user.entity';

/**
 * A separação leitura/escrita acontece AQUI:
 *  - writeRepo usa o DataSource de ESCRITA (HAProxy :5000 -> primário)
 *  - readRepo  usa o DataSource de LEITURA  (HAProxy :5001 -> réplicas)
 *
 * Regra prática: comandos que mudam dados (create) usam o writeRepo;
 * consultas (find) usam o readRepo.
 */
@Injectable()
export class UsersService {
    private readonly writeRepo: Repository<User>;
    private readonly readRepo: Repository<User>;

    constructor(
        @Inject(WRITE_DATA_SOURCE) private readonly writeDS: DataSource,
        @Inject(READ_DATA_SOURCE) private readonly readDS: DataSource,
    ) {
        this.writeRepo = this.writeDS.getRepository(User);
        this.readRepo = this.readDS.getRepository(User);
    }

    /** ESCRITA -> primário */
    create(data: { name: string; email: string }): Promise<User> {
        const user = this.writeRepo.create(data);
        return this.writeRepo.save(user);
    }

    /** LEITURA -> réplica */
    findAll(): Promise<User[]> {
        return this.readRepo.find({ order: { id: 'ASC' } });
    }

    /** LEITURA -> réplica */
    findOne(id: number): Promise<User | null> {
        return this.readRepo.findOne({ where: { id } });
    }

    /**
     * Diagnóstico: mostra em QUAL nó físico cada conexão caiu e se é réplica.
     * Ótimo para "ver funcionando":
     *  - write deve cair sempre no primário (is_replica = false)
     *  - read deve cair numa réplica (is_replica = true)
     */
    async whichNodes(): Promise<{ write: unknown; read: unknown }> {
        const query =
            'SELECT inet_server_addr() AS ip, pg_is_in_recovery() AS is_replica';
        const [write] = await this.writeDS.query(query);
        const [read] = await this.readDS.query(query);
        return { write, read };
    }
}
