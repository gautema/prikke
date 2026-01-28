FROM oven/bun:1-alpine

WORKDIR /app

COPY package.json ./
RUN bun install --production

COPY server.ts ./
COPY static ./static

ENV PORT=8000
EXPOSE 8000

CMD ["bun", "run", "server.ts"]
