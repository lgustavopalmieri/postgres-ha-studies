import {
    BadRequestException,
    Body,
    Controller,
    Get,
    NotFoundException,
    Param,
    ParseIntPipe,
    Post,
} from '@nestjs/common';
import {
    ApiOkResponse,
    ApiOperation,
    ApiTags,
} from '@nestjs/swagger';
import { CreateUserDto } from './dto/create-user.dto';
import { User } from './user.entity';
import { UsersService } from './users.service';

/**
 * Endpoints para testar no Swagger (http://localhost:3000/docs):
 *
 *  POST /users        -> cria usuário   (ESCRITA -> primário :5000)
 *  GET  /users        -> lista usuários (LEITURA -> réplica  :5001)
 *  GET  /users/nodes  -> mostra em qual nó cada conexão caiu (diagnóstico)
 *  GET  /users/:id    -> busca um usuário (LEITURA -> réplica :5001)
 */
@ApiTags('users')
@Controller('users')
export class UsersController {
    constructor(private readonly usersService: UsersService) { }

    @Post()
    @ApiOperation({ summary: 'Cria um usuário (ESCRITA -> primário :5000)' })
    @ApiOkResponse({ type: User })
    create(@Body() body: CreateUserDto) {
        if (!body?.name || !body?.email) {
            throw new BadRequestException(
                'Campos "name" e "email" são obrigatórios.',
            );
        }
        return this.usersService.create({ name: body.name, email: body.email });
    }

    @Get()
    @ApiOperation({ summary: 'Lista usuários (LEITURA -> réplica :5001)' })
    @ApiOkResponse({ type: [User] })
    findAll() {
        return this.usersService.findAll();
    }

    // Rota de diagnóstico ANTES de ":id" para não conflitar com o parâmetro.
    @Get('nodes')
    @ApiOperation({
        summary: 'Diagnóstico: mostra o nó (IP) e se é réplica em cada conexão',
    })
    nodes() {
        return this.usersService.whichNodes();
    }

    @Get(':id')
    @ApiOperation({ summary: 'Busca um usuário por id (LEITURA -> réplica :5001)' })
    @ApiOkResponse({ type: User })
    async findOne(@Param('id', ParseIntPipe) id: number) {
        const user = await this.usersService.findOne(id);
        if (!user) {
            throw new NotFoundException(`Usuário ${id} não encontrado.`);
        }
        return user;
    }
}
