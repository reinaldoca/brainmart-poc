output "ecs_cluster_id"        { value = aws_ecs_cluster.main.id }
output "ecs_cluster_name"      { value = aws_ecs_cluster.main.name }
output "ecs_service_name"      { value = aws_ecs_service.app.name }
output "task_definition_arn"   { value = aws_ecs_task_definition.app.arn }
output "alb_dns_name"          { value = aws_lb.main.dns_name }
output "alb_arn"               { value = aws_lb.main.arn }
output "alb_zone_id"           { value = aws_lb.main.zone_id }
output "target_group_arn"      { value = aws_lb_target_group.app.arn }
output "task_execution_role_arn" { value = aws_iam_role.task_execution.arn }
output "task_role_arn"         { value = aws_iam_role.task.arn }
output "log_group_name"        { value = aws_cloudwatch_log_group.app.name }

output "service_discovery_namespace_id" {
  value = var.enable_service_discovery ? aws_service_discovery_private_dns_namespace.main[0].id : null
}
