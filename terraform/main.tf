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