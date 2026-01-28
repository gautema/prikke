FROM oven/bun:1-alpine

WORKDIR /app

COPY site/package.json ./
RUN bun install --production

COPY site/server.ts ./
COPY site/static ./static
COPY site/pages ./pages
COPY site/templates ./templates

ENV PORT=8000
EXPOSE 8000

CMD ["bun", "run", "server.ts"]
