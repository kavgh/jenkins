provider "aws" {
  shared_config_files      = ["~/.aws/config"]
  shared_credentials_files = ["~/.aws/credentials"]
  profile                  = "default"
}

locals {
  allow = {
    ssh  = 22
    http = 8080
  }
  tags = {
    Purpose = "Jenkins"
  }
}

resource "aws_key_pair" "this" {
  key_name   = "jenkins-pkey"
  public_key = file("~/.ssh/aws_ec2.pub")
}

resource "aws_security_group" "this" {
  name        = "jenkins-sg"
  description = "Security group for the jenkins ec2 instance"

  tags = local.tags
}

resource "aws_vpc_security_group_ingress_rule" "this" {
  for_each = local.allow

  description       = "allow ${each.key} inbound traffic"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = each.value
  to_port           = each.value
  ip_protocol       = "tcp"
  security_group_id = aws_security_group.this.id

  tags = local.tags
}

resource "aws_vpc_security_group_egress_rule" "this" {
  description       = "allow outbound traffic"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = -1
  security_group_id = aws_security_group.this.id

  tags = local.tags
}

resource "aws_instance" "this" {
  ami                         = "ami-085f9c64a9b75eed5"
  associate_public_ip_address = true
  instance_type               = "t2.micro"
  key_name                    = aws_key_pair.this.id
  security_groups             = [aws_security_group.this.id]
  user_data                   = "./resources/provision.sh"

  tags = merge(local.tags, { Name = "Jenkins" })
}
