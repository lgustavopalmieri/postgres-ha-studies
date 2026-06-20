# Imagem da aplicação NestJS.
FROM node:20-bookworm-slim

WORKDIR /usr/src/app

# Instala dependências primeiro (melhor cache de build).
COPY package*.json ./
RUN npm install

# Copia o restante do código e compila o TypeScript -> dist/.
COPY . .
RUN npm run build

EXPOSE 3000

# start:prod roda o JS já compilado. Ao subir, o DatabaseModule conecta no
# primário e aplica as migrations pendentes antes de aceitar requisições.
CMD ["npm", "run", "start:prod"]
