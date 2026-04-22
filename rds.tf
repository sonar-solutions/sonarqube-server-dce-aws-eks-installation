# rds.tf
# RDS Subnet Group
resource "aws_db_subnet_group" "sonarqube" {
  name = "${var.cluster_name}-db-subnet-group"
  description = "Subnet group for the SonarQube RDS instance"
  subnet_ids = module.vpc.private_subnets

  tags = {
    Name = "${var.cluster_name}-db-subnet-group"
    Environment = var.environment
    Owner = var.owner_tag
  }
}

# RDS Security Group
resource "aws_security_group" "rds" {
  name_prefix = "${var.cluster_name}-rds-"
  description = "Security group for the SonarQube RDS instance"
  vpc_id = module.vpc.vpc_id

  # Only allow access from EKS managed node groups (where containers run)
  ingress {
    from_port = 5432
    to_port = 5432
    protocol = "tcp"
    security_groups = [module.eks.node_security_group_id]
    description = "PostgreSQL access from EKS node group only"
  }

  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  depends_on = [
    module.eks
  ]

  tags = {
    Name = "${var.cluster_name}-rds-sg"
    Environment = var.environment
    Owner = var.owner_tag
  }
}

# RDS Instance
resource "aws_db_instance" "sonarqube" {
  engine = "postgres"
  engine_version = "17.6"
  instance_class = "db.t3.medium"
  allocated_storage = 100
  max_allocated_storage = 1000
  storage_type = "gp3"
  storage_encrypted = true
  
  db_name = var.db_name
  username = var.db_username
  password = random_password.sonarqube_db_password.result

  db_subnet_group_name = aws_db_subnet_group.sonarqube.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  
  # Ensure the RDS instance is not publicly accessible
  publicly_accessible = false
  
  backup_retention_period = 7
  backup_window = "03:00-05:00"
  maintenance_window = "sun:05:30-sun:08:00"

  skip_final_snapshot = true
  deletion_protection = false

  depends_on = [
    random_password.sonarqube_db_password,
    module.eks
  ]

  tags = {
    Name = "${var.cluster_name}-db"
    Environment = var.environment
    Owner = var.owner_tag
  }
}