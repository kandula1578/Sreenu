# build the private sub VPCs
resource "aws_subnet" "private" {
  count                   = length(data.aws_availability_zones.available.names)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = false

  tags = merge(
    var.tags,
    {
      Name = "private-${data.aws_availability_zones.available.names[count.index]}",
      # these are used by the aws-load-balancer controller and can be ignored in a non eks setup
      "kubernetes.io/role/internal-elb" = 1,
      "kubernetes.io/cluster/main"      = "shared"
    },
    module.vodafone.security_zone_tags.SecurityZoneI-A
  )
}

# build the public sub VPCs
resource "aws_subnet" "public" {
  count                   = length(data.aws_availability_zones.available.names)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, count.index + 8)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = merge(
    var.tags,
    {
      Name = "public-${data.aws_availability_zones.available.names[count.index]}",
      # these are used by the aws-load-balancer controller and can be ignored in a non eks setup
      "kubernetes.io/role/elb"     = 1,
      "kubernetes.io/cluster/main" = "shared"
    },
    module.vodafone.security_zone_tags.SecurityZoneDMZ
  )
}

resource "aws_route_table_association" "private_natgw" {

  subnet_id      = aws_subnet.private[0].id
  route_table_id = aws_route_table.natgw.id
}

resource "aws_route_table_association" "private_natgw_2" {

  subnet_id      = aws_subnet.private[1].id
  route_table_id = aws_route_table.natgw-main-2.id
}

resource "aws_route_table_association" "private_natgw_3" {

  subnet_id      = aws_subnet.private[2].id
  route_table_id = aws_route_table.natgw-main-3.id
}

resource "aws_route_table_association" "public_igw" {
  count = length(data.aws_availability_zones.available.names)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.igw.id
}
