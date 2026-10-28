# Build context: repository root. Only public Web configuration belongs in ARGs.
FROM node:24-bookworm-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
COPY apps/api/package.json apps/api/package.json
COPY apps/web/package.json apps/web/package.json
RUN npm ci
COPY apps/api/src apps/api/src
COPY apps/api/tsconfig.json apps/api/tsconfig.json
COPY apps/web/src apps/web/src
COPY apps/web/index.html apps/web/index.html
COPY apps/web/tsconfig.json apps/web/tsconfig.json
COPY apps/web/vite.config.ts apps/web/vite.config.ts
ARG VITE_CLOUDBASE_ENV_ID
ARG VITE_PUBLISHABLE_KEY
ARG VITE_CLOUDBASE_REGION=ap-shanghai
RUN test -n "$VITE_CLOUDBASE_ENV_ID" && test -n "$VITE_PUBLISHABLE_KEY"
RUN npm run build

FROM node:24-bookworm-slim AS runtime
WORKDIR /app
COPY package.json package-lock.json ./
COPY apps/api/package.json apps/api/package.json
COPY apps/web/package.json apps/web/package.json
RUN npm ci --omit=dev --workspace apps/api && npm cache clean --force
COPY openapi.yaml ./openapi.yaml
COPY --from=build /app/apps/api/dist ./apps/api/dist
COPY --from=build /app/apps/web/dist ./apps/web/dist
WORKDIR /app/apps/api
ENV NODE_ENV=production PORT=9000 WEB_DIST_PATH=/app/apps/web/dist
USER node
EXPOSE 9000
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 CMD node -e "fetch('http://127.0.0.1:'+process.env.PORT+'/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "dist/server.js"]
