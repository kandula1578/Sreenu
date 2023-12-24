resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(
    var.tags,
    {
      "Name" : "vpc-main",
      "SecurityZone" : "i1"
    },
  )
}

# default security group => disable everything by default
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id
  tags = merge(
    var.tags,
    { "Name" : "vpc-default-sg (do not use)" },
    module.vodafone.security_zone_tags.SecurityZoneI-A
  )
}
