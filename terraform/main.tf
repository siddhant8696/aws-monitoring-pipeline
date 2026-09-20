terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws"{
    region="us-east-1"
}

resource "aws_vpc" "main" {
    cidr_block = "10.1.0.0/16"

    tags = {
        Name = "aws-monitoring-pipeline-vpc"
    }
}

resource "aws_internet_gateway" "main" {
    vpc_id = aws_vpc.main.id

    tags = {
        Name = "aws-monitoring-pipeline-igw"
    }
  
}

resource "aws_subnet" "public" {
  vpc_id = aws_vpc.main.id
  cidr_block = "10.1.1.0/24"
  availability_zone = "us-east-1a"
  map_public_ip_on_launch = true

  tags = {
    Name = "aws-monitoring-pipeline-public-subnet"
  }
}

resource "aws_route_table" "public" {

    vpc_id = aws_vpc.main.id


    route {
        cidr_block = "0.0.0.0/0"
        gateway_id = aws_internet_gateway.main.id
    }

    tags = {
      Name = "aws-monitoring-pipeline-public-rt"
    }
}

resource "aws_route_table_association" "public" {
    subnet_id = aws_subnet.public.id
    route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "ec2" {
  name = "aws-monitoring-pipeline-ec2-sg"
  description = "Allow SSH and outbound traffic"
  vpc_id =  aws_vpc.main.id

  ingress {
    description = "SSH access"
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

    ingress {
    description = "HTTP access"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags ={
    Name = "aws-monitoring-pipeline-ec2-sg"
  }
}

resource "aws_key_pair" "main" {
  key_name = "aws-monitoring-pipeline-key"
  public_key = file("${path.module}/aws-monitoring-pipeline-key.pub")
  }

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners = ["amazon"]

  filter {
    name = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

locals {
  ami_id = data.aws_ami.amazon_linux.id
}

resource "aws_instance" "app" {
    count = 2
    ami = local.ami_id
    instance_type = "t2.micro"
    subnet_id = aws_subnet.public.id
    vpc_security_group_ids = [ aws_security_group.ec2.id ]
    key_name = aws_key_pair.main.key_name

    tags = {
      Name = "aws-monitoring-pipeline-instance-${count.index}"
    }  
}

output "instance_public_ips" {
  value = aws_instance.app[*].public_ip
}

resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  count = 2
  alarm_name = "high-cpu-instance-${count.index}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods = 2
  metric_name = "CPUUtilization"
  namespace = "AWS/EC2"
  period = 120
  statistic = "Average"
  threshold = 80
  alarm_description = "Alarm when CPU exceeds 80%"

  dimensions = {
    InstanceId = aws_instance.app[count.index].id 
  }
}


resource "aws_cloudwatch_metric_alarm" "status_check_failed" {
  count = 2
  alarm_name = "status-check-failed-instance-${count.index}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods = 2
  metric_name = "StatusCheckFailed"
  namespace = "AWS/EC2"
  period = 60
  statistic = "Maximum"
  threshold = 0
  alarm_description = "Alarm when instance status check fails"

  dimensions = {
    InstanceId = aws_instance.app[count.index].id
  }
  
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "aws-monitoring-pipeline-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric"
        x    =  0
        y    =  0
        width = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/EC2", "CPUUtilization", "InstanceId", aws_instance.app[0].id],
            ["AWS/EC2", "CPUUtilization", "InstanceId", aws_instance.app[1].id]
          ]
          period = 300
          stat = "Average"
          region = "us-east-1"
          title = "CPU Utilization"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/EC2", "StatusCheckFailed", "InstanceId", aws_instance.app[0].id],
            ["AWS/EC2", "StatusCheckFailed", "InstanceId", aws_instance.app[1].id]
          ]
          period = 300
          stat   = "Maximum"
          region = "us-east-1"
          title  = "Instance Status Checks"
        }
      }
    ]
  })
  
}

resource "aws_sns_topic" "alerts" {
  name = "aws-monitoring-pipeline-alerts" 
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol = "email"
  endpoint = var.alert_email
  
}

resource "aws_iam_role" "lambda_remediation" {
  name = "aws-monitoring-pipeline-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_remediation_policy" {
  name = "aws-monitoring-pipeline-lambda-policy"
  role = aws_iam_role.lambda_remediation.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ec2:RebootInstances", "ec2:DescribeInstances"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.alerts.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/../lambda/remediate.py"
  output_path = "${path.module}/lambda.zip"
}

resource "aws_lambda_function" "remediation" {
  function_name    = "aws-monitoring-pipeline-remediation"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  handler          = "remediate.lambda_handler"
  runtime          = "python3.12"
  role             = aws_iam_role.lambda_remediation.arn
  timeout          = 30

  environment {
    variables = {
      SNS_TOPIC_ARN = aws_sns_topic.alerts.arn
    }
  }
}

resource "aws_cloudwatch_event_rule" "status_check_alarm" {
  name        = "aws-monitoring-pipeline-status-alarm-rule"
  description = "Triggers when a status check alarm fires"

  event_pattern = jsonencode({
    source      = ["aws.cloudwatch"]
    detail-type = ["CloudWatch Alarm State Change"]
    detail = {
      state = {
        value = ["ALARM"]
      }
      alarmName = [
        "status-check-failed-instance-0",
        "status-check-failed-instance-1"
      ]
    }
  })
}

resource "aws_cloudwatch_event_target" "lambda_target" {
  rule = aws_cloudwatch_event_rule.status_check_alarm.name
  arn  = aws_lambda_function.remediation.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.remediation.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.status_check_alarm.arn
}