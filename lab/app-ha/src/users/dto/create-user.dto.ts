import { ApiProperty } from '@nestjs/swagger';

/**
 * DTO do corpo do POST /users.
 * Os decorators @ApiProperty fazem o Swagger exibir os campos, exemplos e
 * marcar o que é obrigatório no formulário "Try it out".
 */
export class CreateUserDto {
    @ApiProperty({ example: 'Ana Silva', description: 'Nome do usuário' })
    name: string;

    @ApiProperty({
        example: 'ana@example.com',
        description: 'E-mail único do usuário',
    })
    email: string;
}
