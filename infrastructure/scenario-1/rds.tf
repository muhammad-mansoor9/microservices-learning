# Security group — only app-tier instances can reach the database
resource "aws_security_group" "rds" {
  name        = "ms-learning-rds-sg"
  description = "Allow PostgreSQL from app tier only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL from app servers"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "ms-learning-rds-sg" }
}

# RDS needs to know which subnets it can use — we use the two private subnets
resource "aws_db_subnet_group" "main" {
  name       = "ms-learning-db-subnet-group"
  subnet_ids = [aws_subnet.private_a.id, aws_subnet.private_b.id]

  tags = { Name = "ms-learning-db-subnet-group" }
}

# PostgreSQL 16, single-AZ, cheapest instance — fine for a learning project
resource "aws_db_instance" "postgres" {
  identifier        = "ms-learning-postgres"
  engine            = "postgres"
  engine_version    = "16"
  instance_class    = "db.t3.micro"
  allocated_storage = 20
  storage_type      = "gp2"

  # Initial database created on first boot.
  # order_db and payment_db are created afterwards (see outputs for instructions).
  db_name  = "postgres"
  username = "postgres"
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  publicly_accessible = false
  multi_az            = false

  # Backups and deletion protection off — this is a learning environment
  backup_retention_period = 0
  skip_final_snapshot     = true
  deletion_protection     = false

  tags = { Name = "ms-learning-postgres" }
}
