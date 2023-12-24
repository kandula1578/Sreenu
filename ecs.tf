locals {
  asg_tags = merge(
    var.tags,
    {
      Name          = var.cluster_name,
      SecurityZone  = "A",
      "Patch Group" = "${var.cluster_name} ECS cluster"
    },
  )
}

/* ec2 iam role and policies */
resource "aws_iam_role" "ec2-role" {
  name               = "${var.cluster_name}-ec2-role"
  assume_role_policy = <<-EOT
  {
    "Version": "2008-10-17",
    "Statement": [
      {
        "Action": "sts:AssumeRole",
        "Principal": {
          "Service": ["ec2.amazonaws.com"]
        },
        "Effect": "Allow"
      }
    ]
  }
  EOT

  tags = merge(
    var.tags,
    {
      Name = "${var.cluster_name}-ec2-role"
    },
  )
}

resource "aws_iam_policy" "ec2-service-role-policy" {
  name        = "${var.cluster_name}-ec2-service-role-policy"
  path        = "/"
  description = "Access for ECS agent to run on EC2"
  policy      = <<-EOT
  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": [
          "ecs:CreateCluster",
          "ecs:DeregisterContainerInstance",
          "ecs:DiscoverPollEndpoint",
          "ecs:Poll",
          "ecs:RegisterContainerInstance",
          "ecs:StartTelemetrySession",
          "ecs:Submit*",
          "ecs:StartTask",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams",
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:GetRepositoryPolicy",
          "ecr:DescribeRepositories",
          "ecr:ListImages",
          "ecr:DescribeImages",
          "ecr:BatchGetImage"
        ],
        "Resource": "*"
      }
    ]
  }
  EOT
}

module "ecs_ec2_patchmanagement" {
  source = "../ec2_patchmanagement"

  role = aws_iam_role.ec2-role.id
}

resource "aws_iam_policy" "main_cloudwatch_associate_kms" {
  name = "main_cloudwatch_associate_kms"

  policy = <<-EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "VisualEditor0",
            "Effect": "Allow",
            "Action": [
                "logs:AssociateKmsKey",
                "logs:PutRetentionPolicy"
            ],
            "Resource": "*"
        }
    ]
}
EOF

tags = merge(
    var.tags,
    {
      Name = "main_cloudwatch_associate_kms"
    },
  )
}

resource "aws_iam_policy" "create_cw_alarm" {
  name = "create_cw_alarm"

  policy = <<-EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "CreateAlarm",
            "Effect": "Allow",
            "Action": "cloudwatch:PutMetricAlarm",
            "Resource": ["arn:aws:cloudwatch:eu-central-1:${data.aws_caller_identity.current.account_id}:alarm:*-instance-check-fail-alarm"]
        }
    ]
}
EOF

  tags = merge(
    var.tags,
    {
      Name = "create_cw_alarm"
    },
  )
}

resource "aws_iam_role_policy_attachment" "ecs_cloudwatch_alarm_attach" {
  policy_arn =  aws_iam_policy.create_cw_alarm.arn
  role       =  aws_iam_role.ec2-role.id
}

resource "aws_iam_role_policy_attachment" "main_cloudwatch_associate_kms_attach" {
  policy_arn =  aws_iam_policy.main_cloudwatch_associate_kms.arn
  role       =  aws_iam_role.ec2-role.id
}

resource "aws_iam_role_policy_attachment" "CloudwatchAgentServer_attach" {
  policy_arn =  "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
  role       =  aws_iam_role.ec2-role.id
}

resource "aws_iam_role_policy_attachment" "ec2_service_role" {
  policy_arn = aws_iam_policy.ec2-service-role-policy.arn
  role       = aws_iam_role.ec2-role.id
}

resource "aws_iam_instance_profile" "ec2" {
  depends_on = [aws_iam_role.ec2-role]
  name       = "ec2"
  path       = "/"
  role       = aws_iam_role.ec2-role.name
}

resource "aws_security_group" "ecs-ec2" {
  name        = "${var.cluster_name}-ecs-ec2"
  description = "Security Group that allows ssh from bastion host and outgoing http for updates"
  vpc_id      = aws_vpc.main.id

  # ingress {
  #   from_port       = 22
  #   to_port         = 22
  #   protocol        = "tcp"
  #   security_groups = [aws_security_group.bastion_host.id]
  # }

  egress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { "SecurityZone" = "i1" })
}

# locals {
#   modules = {
#     mod_a = module.vodafone.ami_ecs.id
#     mod_b = module.vodafone_t4c.ami_ecs.id
#   }
# }
resource "aws_launch_template" "main" {
  name          = "${var.cluster_name}-template"
  image_id      = module.vodafone.ami_ecs.id
  instance_type = var.ecs_instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2.name
  }

  lifecycle {
    ignore_changes = [latest_version]
  }

  key_name = var.ecs_key_name == "" ? null : var.ecs_key_name

  # note: we should check if the cloudwatch agent is required
  # the trend micro tenant id used here is country specific. so far we only use german servers so hardcoding is ok
  # https://confluence.sp.vodafone.com/display/GPCS/Trend+Micro+Deep+Security+for+AWS
  # qualys agent activation id and customerid seems to be static
  # IMPORTANT
  # *************************************************************************************************
  # Do one manual reboot after creating instances so that if kernel upgrade can happen(if applicable).
  # After this , AWS patch manager for future upgrades.
  # **************************************************************************************************
  user_data = base64encode(<<-EOT
    #!/bin/bash -xe
    cat > /etc/docker/daemon.json <<EOF
    {
      "insecure-registries": ["registry.ecs-cluster.internal"],
      "registry-mirrors": ["https://registry.ecs-cluster.internal"]
    }
    EOF
    # Qualys scanner wants ip forwarding disabled. As we are using dedicated ENIs we don't need it (would be needed for bridged networking)
    sysctl -w net.ipv4.ip_forward=0
    #removing CIS benchmarking tool which has log4j reference. PCS team will create new image team fixing this one.
    sudo rm -rf /usr/local/share/vodafone/pcs/image-hardening/cis-cat/cis-cat-full
    sudo amazon-linux-extras enable docker
    # docker defaults to enabling it during start...disable it
    echo "OPTIONS=--ip-forward=false $OPTIONS" >> /etc/sysconfig/docker
    systemctl restart docker
    tee /etc/ecs/ecs.config <<EOF
    ECS_CLUSTER=${var.cluster_name}
    ECS_ENABLE_CONTAINER_METADATA=true
    ECS_ENABLE_TASK_ENI=true
    EOF
    # what nonsense is this?
    sudo chmod -x /usr/bin/scp
    sudo chmod -x /bin/scp
    sleep 1
    # let everything settle..dsa interferes with our setup it seems
    sleep 10
    /opt/ds_agent/dsa_control -r || true
    /opt/ds_agent/dsa_control -a dsm://trend-dsm.aws-shared.vodafone.com:4120/ "tenantId:49A6C9FB-B980-039B-999C-B02FD4EE07FB" || true
    sleep 1
    service qualys-cloud-agent stop
    /usr/local/qualys/cloud-agent/bin/qualys-cloud-agent.sh ActivationId=6f5d2eec-ba86-443c-88af-07a394fc3148 CustomerId=3f751192-e92e-d42e-83ce-c5a54f519118
    service qualys-cloud-agent status | grep 'Active:'
    echo "Cloud init finished"
    EOT
  )

    metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
    }

  network_interfaces {
    associate_public_ip_address = false
    delete_on_termination       = true
    security_groups = [
      aws_security_group.ecs-ec2.id,
      aws_security_group.trend_micro_agent_outgoing.id
    ]
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(
      var.tags,
      {
        SecurityZone = "A"
      },
    )
  }

  tags = merge(
    var.tags,
    {
      Name         = "${var.cluster_name}-template",
      SecurityZone = "A",
      trend-plan   = "linux-min"

    },
  )
}


resource "aws_autoscaling_group" "main" {
  name                      = var.cluster_name
  min_size                  = 0
  max_size                  = 20
  health_check_grace_period = 300
  health_check_type         = "ELB"
  vpc_zone_identifier       = aws_subnet.private[*].id

  #ECS capacity provider will manage instance.
  protect_from_scale_in = "true"

  launch_template {
    id      = aws_launch_template.main.id
    version = "$Latest"
  }

  lifecycle {
    ignore_changes = [desired_capacity]
  }

  tags = concat(
    [for k in keys(local.asg_tags) : { key = k, value = local.asg_tags[k], propagate_at_launch = true }],
  )
}


resource "aws_ecs_capacity_provider" "main" {
  name = var.cluster_name

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.main.arn
    managed_termination_protection = "ENABLED"

    # not totally understood should be investigated
    managed_scaling {
      maximum_scaling_step_size = 10
      minimum_scaling_step_size = 1
      status                    = "ENABLED"
      target_capacity           = 100
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}


# Create an ECS cluster
resource "aws_ecs_cluster" "main" {
  depends_on = [aws_autoscaling_group.main]

  name               = var.cluster_name
  capacity_providers = [aws_ecs_capacity_provider.main.name]

  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.main.name
    weight            = 1
    base              = 0
  }

  setting {
    # Enable CloudWatch Container Insights
    name  = "containerInsights"
    value = "enabled"
  }

  lifecycle {
    ignore_changes = [setting]
  }

  tags = merge(
    var.tags,
    {
      Name = var.cluster_name
    },
  )
}
