# syntax=docker/dockerfile:1
# Three stages: install, build, run. The runtime image holds only the
# standalone server, static files and public assets, as a non-root user.

FROM node:22-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

FROM node:22-alpine AS build
WORKDIR /app
ENV NEXT_TELEMETRY_DISABLED=1
COPY --from=deps /app/node_modules ./node_modules
COPY . .
ARG CMA_VERSION=dev
ENV CMA_VERSION=$CMA_VERSION
RUN npm run build

FROM node:22-alpine AS run
WORKDIR /app
ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=8080 \
    HOSTNAME=0.0.0.0
ARG CMA_VERSION=dev
ENV CMA_VERSION=$CMA_VERSION
RUN addgroup -S app && adduser -S app -G app
COPY --from=build --chown=app:app /app/.next/standalone ./
COPY --from=build --chown=app:app /app/.next/static ./.next/static
COPY --from=build --chown=app:app /app/public ./public
# The scheduler's jobs (migration 0005a, addition 0008s): the same image runs them as Cloud Run jobs with another command
COPY --from=build --chown=app:app /app/jobs ./jobs
# System health documents (addition 0008r): copied into web/documents/ by cloudbuild.yaml before the build, listed by
# scripts/documents-manifest.mjs at prebuild; an empty directory with an empty manifest when the copy step did not run
COPY --from=build --chown=app:app /app/documents ./documents
USER app
EXPOSE 8080
CMD ["node", "server.js"]
