resource "aws_ecs_task_definition" "example" {
  family             = "example"
  network_mode       = "awsvpc"
  task_role_arn      =  aws_iam_role.task-role.arn
  execution_role_arn = var.ecs_task_execution_role

  container_definitions = jsonencode([
    {
      "logConfiguration" : {
        "logDriver" : "awslogs",
        "options" : {
          "awslogs-create-group" : "true",
          "awslogs-region" : "eu-central-1",
          "awslogs-group" : "daas_cas"
        }
      },
      "name" : "example",
      "image" : "${data.aws_caller_identity.current.account_id}.dkr.ecr.eu-central-1.amazonaws.com",
      "environment" : [
          {
            "name" : "SPRING_PROFILES_ACTIVE",
            "value" : var.spring_profiles_active
          },
          {
            "name" : "SERVICE_BASIC_AUTH_CREDENTIALS_FILE_PATH",
            "value" : var.service_basic_auth_credentials_file_path_cas
          },
          {
            "name" : "BACKEND_SERVER_PORT",
            "value" : "8090"
          },
            {
            "name" : "CI_CONFIG_SYS_CLIENT_ID_UAT",
            "value": local.env_variable.CI_CONFIG_SYS_CLIENT_ID_UAT
          },
           {
            "name" : "CI_CONFIG_SYS_CLIENT_SECRET_UAT",
            "value": local.env_variable.CI_CONFIG_SYS_CLIENT_SECRET_UAT
          },
           {
            "name" : "CI_CONFIG_SYS_CLIENT_ID_PROD",
            "value": local.env_variable.CI_CONFIG_SYS_CLIENT_ID_PROD
          },
           {
            "name" : "CI_CONFIG_SYS_CLIENT_SECRET_PROD",
            "value": local.env_variable.CI_CONFIG_SYS_CLIENT_SECRET_PROD
          }
        ],
      "cpu" : 128,
      "memory" : 1024,
      "essential" : true,
      "portMappings" : [
        {
          "containerPort" : 8090

        }
      ]
    },
      {
        "logConfiguration" : {
          "logDriver" : "awslogs",
          "options" : {
            "awslogs-create-group" : "true",
            "awslogs-region" : "eu-central-1",
            "awslogs-group" : "example-proxy"
          }
        },
        "image" : "${data.aws_caller_identity.current.account_id}.dkr.ecr.eu-central-1.amazonaws.com",
        "memory" : 128,
        "cpu" : 128,
        "name" : "example-proxy",
        "portMappings" : [
          {
            "containerPort" : 443
          }
        ],
        "environment" : [
          {
            "name" : "PROXY_CONFIGURATION",
            "value" : <<-EOT
location / {
  proxy_pass http://localhost:8090;
}
EOT
          }

        ]
      }
    ]
  )
}

resource "aws_ecs_service" "example" {
  name            = "example"
  cluster         = var.cluster_name
  task_definition = aws_ecs_task_definition.example.arn
  desired_count   = 2

  load_balancer {
    target_group_arn = aws_lb_target_group.internal.arn
    container_name   = "example-proxy"
    container_port   = 443
  }

  network_configuration {
    subnets = var.private_subnets

    security_groups = [
      aws_security_group.example.id
    ]
  }
  enable_ecs_managed_tags = true
  propagate_tags          = "SERVICE"

  lifecycle {
    ignore_changes = [capacity_provider_strategy, desired_count]
  }

  ordered_placement_strategy {
    type  = "spread"
    field = "attribute:ecs.availability-zone"
  }

  placement_constraints {
    type = "distinctInstance"
  }

  deployment_controller {
    type = "ECS"
  }

  timeouts{
    delete="10m"
  }

  tags = merge(
    var.tags,
    {
      "SecurityZone" = "A"
    }
  )
}

resource "aws_lb_target_group" "daas_cas_internal" {
  name       = "lb-target-daas-cas-${substr(uuid(), 0, 3)}"
  port       = 443
  protocol   = "HTTPS"
  slow_start = 0
  # need to specify ip type because we are using awsvpc docker networking
  target_type = "ip"
  vpc_id      = var.vpc_id

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [name]
  }

   health_check {
    enabled             = true
    healthy_threshold   = 3
    interval            = 30
    port                = "443"
    protocol            = "HTTPS"
    path                = "/cas/health/ready"
    unhealthy_threshold = 3
  }


  tags = merge(
    var.tags,
    { "Name" : "lb-target-daas-cas-internal" }
  )
}



resource "aws_security_group" "daas_cas" {
  name        = "daas-cas service sg"
  description = "Security Group for daas_cas"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Incoming traffic from nlb to daas_cas"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [var.alb_sg_id]
  }

  egress {
      description     = "outgoing traffic from daas_cas to internet"
      from_port        = 80
      to_port          = 80
      protocol         = "tcp"
      cidr_blocks      = ["0.0.0.0/0"]
  }

   egress {
      description     = "outgoing traffic from daas_cas to internet"
      from_port        = 443
      to_port          = 443
      protocol         = "tcp"
      cidr_blocks      = ["0.0.0.0/0"]
  }


  tags = merge(var.tags, { "SecurityZone" = "i1" })
}

resource "aws_lb_listener_rule" "daas_cas" {
  listener_arn = var.lb_listener_arn

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.daas_cas_internal.arn
  }

  condition {
    path_pattern {
      values = ["/cas","/cas/*"]
    }
  }
}



# resource "aws_lb_listener" "nlb-internal-https" {
#   load_balancer_arn = aws_lb.eecc-ccs-nlb-internal.arn
#   port              = "443"
#   protocol          = "TLS"
#   certificate_arn   = var.certificate_arn
#   ssl_policy        = "ELBSecurityPolicy-FS-1-2-Res-2020-10"

#   default_action {
#     type             = "forward"
#     target_group_arn = aws_lb_target_group.eecc_ccs_internal.arn
#   }
# }


# resource "aws_cloudwatch_log_subscription_filter" "datadog_log_subscription_eecc_ccs" {
# name = "datadog_log_subscription_eecc_ccs"
# log_group_name = "eecc_ccs"
# # hardcoded for now. unclear if this can be dynamic in real life?
# destination_arn = "arn:aws:lambda:eu-central-1:${data.aws_caller_identity.current.account_id}:function:datadog-forwarder" # e.g., arn:aws:lambda:us-east-1:123:function:datadog-forwarder
# filter_pattern = ""
# }

# resource "aws_cloudwatch_log_subscription_filter" "datadog_log_subscription_eecc_ccs_proxy" {
# name = "datadog_log_subscription_eecc_ccs_proxy"
# log_group_name = "eecc-ccs-proxy"
# # hardcoded for now. unclear if this can be dynamic in real life?
# destination_arn = "arn:aws:lambda:eu-central-1:${data.aws_caller_identity.current.account_id}:function:datadog-forwarder" # e.g., arn:aws:lambda:us-east-1:123:function:datadog-forwarder
# filter_pattern = ""
# }
