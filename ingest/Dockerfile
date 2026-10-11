# syntax=docker/dockerfile:1
# The ingest service (cma-ingest) and its jobs on the same image (Cloud Run jobs: node jobs/<name>.mjs).
# Two stages: production dependencies, then the runtime as a non-root user.

FROM node:22-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund

FROM node:22-alpine AS run
WORKDIR /app
ENV NODE_ENV=production \
    PORT=8080
ARG INGEST_VERSION=dev
ENV INGEST_VERSION=$INGEST_VERSION
RUN addgroup -S app && adduser -S app -G app
COPY --from=deps --chown=app:app /app/node_modules ./node_modules
COPY --chown=app:app package.json ./
COPY --chown=app:app src ./src
COPY --chown=app:app jobs ./jobs
USER app
EXPOSE 8080
CMD ["node", "src/server.mjs"]
