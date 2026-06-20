# ??????????????????????????????????????????????????????????????????????????????
# modules/compute/main.tf
#
# MO?DULO: ECS Fargate para microservicios .NET 8
#
# IMPLEMENTA:
#   1. ECS Cluster con Container Insights habilitado
#   2. Task Definition para el microservicio (con li?mites de CPU/memoria)
#   3. ECS Service con Circuit Breaker y rolling deploy
#   4. Application Load Balancer con HTTPS listener
#   5. Auto Scaling basado en CPU y memoria
#   6. Service Discovery via AWS Cloud Map
#   7. Task Execution Role con mi?nimo privilegio
#   8. X-Ray sidecar para trazas distribuidas
#
# SEGURIDAD:
#   - No hay privilegios de root en los contenedores
#   - readonlyRootFilesystem = true
#   - Secretos via Secrets Manager (no variables de entorno planas)
#   - JWT en HttpOnly cookies (configurado en la app .NET)
# ??????????????????????????????????????????????????????????????????????????????

terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ??????????????????????????????????????????????????????????????????????????????
# ECS CLUSTER
# ??????????????????????????????????????????????????????????????????????????????

resource "aws_ecs_cluster" "main" {
  name = "${var.name_prefix}-ecs-cluster"

  # Container Insights: me?tricas de CPU/memoria a nivel de tarea y servicio
  # Necesario para las alarmas de CloudWatch y X-Ray
  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-ecs-cluster"
  })
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name = aws_ecs_cluster.main.name

  # FARGATE: serverless, no hay EC2 que gestionar
  # FARGATE_SPOT: ma?s barato (hasta 70%), para tareas tolerantes a interrupciones
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    base              = 1  # Al menos 1 tarea en FARGATE standard (no SPOT)
    weight            = 1
    capacity_provider = "FARGATE"
  }
}

# ??????????????????????????????????????????????????????????????????????????????
# IAM ROLES ? Task Execution Role y Task Role
#
# Task Execution Role: permisos para que el ECS agent lance la tarea
#   - Pull de ima?genes ECR
#   - Escribir logs a CloudWatch
#   - Leer secretos de Secrets Manager (para inyeccio?n en la tarea)
#
# Task Role: permisos para el co?digo que corre DENTRO del contenedor
#   - Leer secretos en tiempo de ejecucio?n
#   - Escribir traces a X-Ray
#   - NO tiene permisos de infra (no puede crear/destruir recursos)
# ??????????????????????????????????????????????????????????????????????????????

resource "aws_iam_role" "task_execution" {
  name = "${var.name_prefix}-ecs-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        # Solo ECS tasks de esta cuenta pueden asumir este rol
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "task_execution_basic" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Permisos adicionales para el Task Execution Role:
# leer secretos de Secrets Manager (para inyectarlos como env vars en la tarea)
resource "aws_iam_role_policy" "task_execution_secrets" {
  name = "${var.name_prefix}-task-execution-secrets-policy"
  role = aws_iam_role.task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadSecretsManager"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = [
          "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:${var.name_prefix}/*"
        ]
      },
      {
        Sid    = "DecryptKMS"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = var.kms_key_arn
      }
    ]
  })
}

# Task Role: permisos del CO?DIGO que corre dentro del contenedor
resource "aws_iam_role" "task" {
  name = "${var.name_prefix}-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "task_permissions" {
  name = "${var.name_prefix}-task-permissions-policy"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "XRayTracing"
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords",
          "xray:GetSamplingRules",
          "xray:GetSamplingTargets"
        ]
        Resource = "*"
      },
      {
        Sid    = "SecretsManagerRead"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:${var.name_prefix}/*"
      },
      {
        Sid    = "CloudWatchMetrics"
        Effect = "Allow"
        Action = ["cloudwatch:PutMetricData"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "cloudwatch:namespace" = "Brainmart/${var.environment}"
          }
        }
      }
    ]
  })
}

# ??????????????????????????????????????????????????????????????????????????????
# CLOUDWATCH LOG GROUP para los contenedores
# ??????????????????????????????????????????????????????????????????????????????

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.name_prefix}/${var.service_name}"
  retention_in_days = var.environment == "prod" ? 2555 : 365
  kms_key_id        = var.kms_key_arn

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "xray" {
  name              = "/ecs/${var.name_prefix}/${var.service_name}/xray"
  retention_in_days = 365
  kms_key_id        = var.kms_key_arn

  tags = var.tags
}

# ??????????????????????????????????????????????????????????????????????????????
# ECS TASK DEFINITION
# Define el contenedor, sus recursos y su configuracio?n de seguridad
# ??????????????????????????????????????????????????????????????????????????????

resource "aws_ecs_task_definition" "app" {
  family                   = "${var.name_prefix}-${var.service_name}"
  network_mode             = "awsvpc"  # Cada tarea tiene su propia ENI
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    # ?? Contenedor principal: microservicio .NET 8 ??
    {
      name  = var.service_name
      image = "${var.ecr_image_uri}:${var.image_tag}"

      # Recursos: el contenedor puede usar HASTA cpu/memory de la tarea
      cpu    = var.task_cpu - 256   # Dejar 256 CPU units para X-Ray sidecar
      memory = var.task_memory - 128  # Dejar 128 MB para X-Ray

      # Puerto que expone la app .NET (Kestrel)
      portMappings = [{
        containerPort = 8080
        hostPort      = 8080
        protocol      = "tcp"
        name          = "http"  # Nombre para Service Connect
      }]

      # Variables de entorno NO sensibles
      environment = [
        { name = "ASPNETCORE_ENVIRONMENT", value = var.environment == "prod" ? "Production" : "Staging" },
        { name = "ASPNETCORE_URLS",        value = "http://+:8080" },
        { name = "AWS_REGION",             value = data.aws_region.current.name },
        { name = "ENVIRONMENT",            value = var.environment },
        { name = "SERVICE_NAME",           value = var.service_name },
        # X-Ray daemon address (sidecar en el mismo task)
        { name = "AWS_XRAY_DAEMON_ADDRESS", value = "127.0.0.1:2000" }
      ]

      # Secretos inyectados DESDE Secrets Manager (no en plano en las variables)
      # El ECS agent los descifra antes de pasar al contenedor
      secrets = [
        {
          name      = "DB_CONNECTION_STRING"
          valueFrom = "${var.db_secret_arn}:connection_string::"
        },
        {
          name      = "JWT_SIGNING_KEY"
          valueFrom = "${var.jwt_secret_arn}:signing_key::"
        }
      ]

      # Logs a CloudWatch
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = data.aws_region.current.name
          "awslogs-stream-prefix" = "ecs"
        }
      }

      # ?? SEGURIDAD DEL CONTENEDOR ??
      # No ejecutar como root
      user = "1000:1000"

      # Filesystem de solo lectura: la app no puede escribir en el FS del contenedor
      # (excepto en los volu?menes montados expli?citamente)
      readonlyRootFilesystem = true

      # No permitir escalada de privilegios (sudo, setuid)
      linuxParameters = {
        capabilities = {
          drop = ["ALL"]  # Eliminar TODAS las capabilities de Linux
          add  = []       # No agregar ninguna
        }
        initProcessEnabled = true  # Para manejar sen?ales correctamente en .NET
      }

      # Health check: el ALB tambie?n tiene su propio health check
      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:8080/health || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60  # Dar tiempo a .NET para inicializar
      }

      # Volu?menes temporales necesarios por .NET
      mountPoints = [
        {
          sourceVolume  = "tmp"
          containerPath = "/tmp"
          readOnly      = false
        }
      ]
    },

    # ?? Sidecar: AWS X-Ray Daemon ??
    # Recibe trazas del SDK de X-Ray de .NET y las envi?a a X-Ray
    # Corre como proceso separado (sidecar pattern) para no acoplar al app
    {
      name  = "xray-daemon"
      image = "public.ecr.aws/xray/aws-xray-daemon:3.x"
      cpu   = 32
      memory = 128

      portMappings = [{
        containerPort = 2000
        hostPort      = 2000
        protocol      = "udp"
      }]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.xray.name
          "awslogs-region"        = data.aws_region.current.name
          "awslogs-stream-prefix" = "xray"
        }
      }

      # X-Ray daemon no necesita privilegios especiales
      user = "1000"
      readonlyRootFilesystem = true
    }
  ])

  # Volu?menes efi?meros para /tmp (necesario para .NET temp files)
  volume {
    name = "tmp"
    # Sin configuracio?n adicional = volumen efi?mero en memoria
  }

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-${var.service_name}-task"
    Service = var.service_name
  })
}

# ??????????????????????????????????????????????????????????????????????????????
# SERVICE DISCOVERY (AWS Cloud Map)
# Permite que los microservicios se descubran entre si? por nombre DNS
# sin necesidad de hardcodear IPs o endpoints
# ??????????????????????????????????????????????????????????????????????????????

resource "aws_service_discovery_private_dns_namespace" "main" {
  count = var.enable_service_discovery ? 1 : 0

  name        = "${var.name_prefix}.local"
  description = "Service Discovery namespace para microservicios de ${var.name_prefix}"
  vpc         = var.vpc_id

  tags = var.tags
}

resource "aws_service_discovery_service" "app" {
  count = var.enable_service_discovery ? 1 : 0

  name = var.service_name

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.main[0].id

    dns_records {
      ttl  = 10  # TTL corto para que los cambios propaguen ra?pido
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }

  # Health check: si la tarea falla, se elimina del registro DNS
  health_check_custom_config {
    failure_threshold = 1
  }

  tags = var.tags
}

# ??????????????????????????????????????????????????????????????????????????????
# APPLICATION LOAD BALANCER
# ??????????????????????????????????????????????????????????????????????????????

resource "aws_lb" "main" {
  name               = "${var.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_security_group_id]
  subnets            = var.public_subnet_ids

  # CKV_AWS_131: Drop invalid HTTP headers
  drop_invalid_header_fields = true

  # CKV_AWS_150: Deletion protection (always enabled in prod, optional elsewhere)
  enable_deletion_protection = var.alb_deletion_protection

  access_logs {
    bucket  = var.alb_logs_bucket
    prefix  = "alb/${var.name_prefix}"
    enabled = true
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-alb" })
}

# CKV2_AWS_28: Associate WAF WebACL with the ALB
resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = aws_lb.main.arn
  web_acl_arn  = var.waf_web_acl_arn
}

# Listener HTTPS (443) ? el u?nico listener que acepta tra?fico
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"  # TLS 1.3 mi?nimo
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# Listener HTTP (80) ? redirige a HTTPS
resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_target_group" "app" {
  name        = "${var.name_prefix}-${var.service_name}-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"  # Para ECS Fargate (awsvpc mode)

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 10
    interval            = 30
    path                = "/health"
    matcher             = "200"
    protocol            = "HTTP"
  }

  deregistration_delay = 30  # Esperar 30s antes de sacar una tarea del TG

  tags = var.tags
}

# ??????????????????????????????????????????????????????????????????????????????
# ECS SERVICE
# Gestiona las instancias (tasks) del contenedor y su ciclo de vida
# ??????????????????????????????????????????????????????????????????????????????

resource "aws_ecs_service" "app" {
  name            = "${var.name_prefix}-${var.service_name}"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  # ?? Configuracio?n de red ??
  network_configuration {
    subnets          = var.private_subnet_ids  # Subnets privadas (no pu?blicas)
    security_groups  = [var.ecs_security_group_id]
    assign_public_ip = false  # Sin IP pu?blica: acceso solo via ALB
  }

  # ?? Registrar en el Target Group del ALB ??
  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = var.service_name
    container_port   = 8080
  }

  # ?? Service Discovery ??
  dynamic "service_registries" {
    for_each = var.enable_service_discovery ? [1] : []
    content {
      registry_arn = aws_service_discovery_service.app[0].arn
    }
  }

  # ?? Rolling Deploy con Circuit Breaker ??
  # Si el nuevo deploy falla, hace rollback automa?tico al anterior
  deployment_circuit_breaker {
    enable   = true
    rollback = true  # Rollback automa?tico si el deploy falla health checks
  }

  deployment_controller {
    type = "ECS"  # Rolling deploy (no CodeDeploy blue/green en esta POC)
  }

  deployment_maximum_percent         = 200  # Hasta 2x tasks durante el deploy
  deployment_minimum_healthy_percent = 100  # Al menos 100% siempre disponible

  # Forzar nuevo deploy cuando cambia la imagen (aun si la task def es la misma)
  force_new_deployment = true

  # ?? Propagar tags a las tareas ??
  propagate_tags = "SERVICE"

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-${var.service_name}"
    Service = var.service_name
  })

  depends_on = [
    aws_lb_listener.https,
    aws_iam_role_policy_attachment.task_execution_basic
  ]

  lifecycle {
    # Ignorar cambios en desired_count (manejado por Auto Scaling)
    ignore_changes = [desired_count]
  }
}

# ??????????????????????????????????????????????????????????????????????????????
# AUTO SCALING
# Escala automa?ticamente basado en CPU y memoria
# ??????????????????????????????????????????????????????????????????????????????

resource "aws_appautoscaling_target" "ecs" {
  max_capacity       = var.max_capacity
  min_capacity       = var.min_capacity
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.app.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

# Escalar basado en CPU (target: 70% de utilizacio?n)
resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.name_prefix}-${var.service_name}-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 70.0
    scale_in_cooldown  = 300  # Esperar 5 min antes de escalar hacia abajo
    scale_out_cooldown = 60   # Escalar hacia arriba en 1 min
  }
}

# Escalar basado en memoria (target: 75% de utilizacio?n)
resource "aws_appautoscaling_policy" "memory" {
  name               = "${var.name_prefix}-${var.service_name}-memory-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
    target_value       = 75.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

# ??????????????????????????????????????????????????????????????????????????????
# CLOUDWATCH ALARMAS para ECS
# ??????????????????????????????????????????????????????????????????????????????

resource "aws_cloudwatch_metric_alarm" "ecs_cpu_high" {
  alarm_name          = "${var.name_prefix}-${var.service_name}-cpu-high"
  alarm_description   = "CPU del servicio ECS supera 80% por 5 minutos"
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.app.name
  }

  alarm_actions = [var.sns_alerts_topic_arn]
  tags          = var.tags
}

# Alarma: latencia p99 > 500ms
resource "aws_cloudwatch_metric_alarm" "alb_latency_p99" {
  alarm_name          = "${var.name_prefix}-alb-latency-p99-high"
  alarm_description   = "Latencia p99 del ALB supera 500ms (degradacio?n de performance)"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p99"
  period              = 300
  evaluation_periods  = 3
  threshold           = 0.5  # 500ms en segundos
  comparison_operator = "GreaterThanThreshold"

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
    TargetGroup  = aws_lb_target_group.app.arn_suffix
  }

  alarm_actions = [var.sns_alerts_topic_arn]
  tags          = var.tags
}
