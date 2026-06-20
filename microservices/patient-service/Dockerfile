# syntax=docker/dockerfile:1.6
# ─────────────────────────────────────────────────────────────────────────────
# Dockerfile multi-stage para Patient Service .NET 8
#
# ETAPAS:
#   1. build-deps: restore dependencias (cacheable)
#   2. build:      compilar y publicar
#   3. runtime:    imagen final mínima (sin SDK, sin build tools)
#
# SEGURIDAD:
#   - Imagen base: mcr.microsoft.com/dotnet/aspnet (no SDK en producción)
#   - Usuario no-root: UID 1000 (definido en la imagen base como 'app')
#   - readonlyRootFilesystem compatible: solo /tmp es writable
#   - Sin secrets en el build: todos los secrets vienen de Secrets Manager
#   - Vulnerability scanning: Trivy en el pipeline escanea esta imagen
# ─────────────────────────────────────────────────────────────────────────────

# ── ETAPA 1: Restaurar dependencias NuGet (cacheable) ──────────────────────
FROM mcr.microsoft.com/dotnet/sdk:8.0-alpine AS build-deps

WORKDIR /source

# Copiar solo los archivos de proyecto para aprovechar la caché de Docker
# Si no cambian las dependencias, esta capa se cachea
COPY src/PatientService/PatientService.csproj ./src/PatientService/
RUN dotnet restore ./src/PatientService/PatientService.csproj \
    --runtime linux-musl-x64 \
    --no-cache

# ── ETAPA 2: Build y publicar ──────────────────────────────────────────────
FROM build-deps AS build

WORKDIR /source

# Copiar el código fuente
COPY src/ ./src/

# Argumentos de build para trazabilidad
ARG BUILD_DATE
ARG GIT_COMMIT
ARG VERSION

# Publicar: self-contained=false (usa el runtime de la imagen base)
RUN dotnet publish ./src/PatientService/PatientService.csproj \
    --configuration Release \
    --runtime linux-musl-x64 \
    --no-restore \
    --no-self-contained \
    --output /app/publish \
    -p:Version=${VERSION:-1.0.0} \
    -p:InformationalVersion="${VERSION:-1.0.0}+${GIT_COMMIT:-unknown}"

# ── ETAPA 3: Tests (opcional, se puede saltar con --target build) ──────────
FROM build AS test

WORKDIR /source
COPY tests/ ./tests/

RUN dotnet test ./tests/PatientService.Tests/PatientService.Tests.csproj \
    --no-restore \
    --configuration Release \
    --collect:"XPlat Code Coverage" \
    --results-directory /test-results \
    --logger "trx;LogFileName=results.trx"

# ── ETAPA 4: Runtime — imagen final (sin SDK) ──────────────────────────────
FROM mcr.microsoft.com/dotnet/aspnet:8.0-alpine AS runtime

# Instalar curl solo para el health check (sin APK en runtime si es posible)
# En Alpine, curl se usa para el health check del Dockerfile
RUN apk add --no-cache curl

# Crear usuario no-root (la imagen base ya tiene el usuario 'app' con UID 65534)
# Usamos el usuario estándar de la imagen base para compatibilidad
USER app

WORKDIR /app

# Copiar los artefactos compilados de la etapa de build
COPY --from=build /app/publish .

# Metadata OCI (Open Container Initiative)
# Estos labels se usan por Cosign para verificar la procedencia
ARG BUILD_DATE
ARG GIT_COMMIT
ARG VERSION

LABEL org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${GIT_COMMIT}" \
      org.opencontainers.image.version="${VERSION:-1.0.0}" \
      org.opencontainers.image.title="Brainmart Patient Service" \
      org.opencontainers.image.description="FDA 21 CFR Part 11 Compliant Patient Service" \
      org.opencontainers.image.vendor="Brainmart Health" \
      com.brainmart.compliance="FDA-21CFR11-GCP-ALCOA-GDPR"

# Puerto que expone Kestrel
EXPOSE 8080

# Health check del contenedor (el ALB tiene el suyo aparte)
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

# Entrypoint: iniciar el microservicio
ENTRYPOINT ["dotnet", "PatientService.dll"]
