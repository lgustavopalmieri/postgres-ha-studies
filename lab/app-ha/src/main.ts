import 'reflect-metadata';
import { Logger } from '@nestjs/common';
import { NestFactory } from '@nestjs/core';
import { DocumentBuilder, SwaggerModule } from '@nestjs/swagger';
import { AppModule } from './app.module';

async function bootstrap() {
  const logger = new Logger('Bootstrap');
  // A criação da app dispara o DatabaseModule, que conecta no primário e
  // RODA AS MIGRATIONS antes de a aplicação começar a atender requisições.
  const app = await NestFactory.create(AppModule);
  app.enableShutdownHooks();

  // --- Swagger ---------------------------------------------------------
  // Gera a documentação interativa a partir dos decorators dos controllers.
  // Disponível em http://localhost:3000/docs
  const config = new DocumentBuilder()
    .setTitle('PostgreSQL HA - API de exemplo')
    .setDescription(
      'Demonstra separação leitura/escrita: POST usa o primário (:5000), ' +
      'GET usa as réplicas (:5001).',
    )
    .setVersion('1.0')
    .build();
  const document = SwaggerModule.createDocument(app, config);
  SwaggerModule.setup('docs', app, document);

  const port = parseInt(process.env.PORT ?? '3000', 10);
  await app.listen(port, '0.0.0.0');
  logger.log(`API ouvindo em http://localhost:${port}`);
  logger.log(`Swagger UI em http://localhost:${port}/docs`);
}

void bootstrap();
