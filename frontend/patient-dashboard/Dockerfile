# syntax=docker/dockerfile:1.6
# ─────────────────────────────────────────────────────────────────────────────
# Dockerfile para Angular 17 SPA
# Multi-stage: build con Node.js, runtime con nginx Alpine
# ─────────────────────────────────────────────────────────────────────────────

# ── ETAPA 1: Build de Angular ─────────────────────────────────────────────────
FROM node:20-alpine AS builder

WORKDIR /app

# Copiar manifiestos primero para cachear la capa de dependencias
COPY package*.json ./
RUN npm ci --prefer-offline

# Copiar fuente y compilar para producción
COPY . .

ARG BUILD_ENV=production
RUN npm run build -- --configuration=${BUILD_ENV} --output-hashing=all

# ── ETAPA 2: Runtime con nginx ────────────────────────────────────────────────
FROM nginx:1.25-alpine AS runtime

# Copiar el build de Angular al directorio de nginx
COPY --from=builder /app/dist/patient-dashboard/browser /usr/share/nginx/html

# Copiar configuración de nginx con headers de seguridad
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Remover la configuración por defecto de nginx
RUN rm /etc/nginx/conf.d/default.conf.bak 2>/dev/null || true

# Usuario no-root
RUN chown -R nginx:nginx /usr/share/nginx/html && \
    chown -R nginx:nginx /var/cache/nginx && \
    chown -R nginx:nginx /var/log/nginx && \
    touch /var/run/nginx.pid && \
    chown -R nginx:nginx /var/run/nginx.pid

USER nginx

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=3s \
    CMD wget -qO- http://localhost:80/health || exit 1

LABEL org.opencontainers.image.title="Brainmart Patient Dashboard" \
      org.opencontainers.image.description="Angular 17 SPA for clinical trial management"

CMD ["nginx", "-g", "daemon off;"]
