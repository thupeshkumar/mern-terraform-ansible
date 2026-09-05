variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Prefix used to name/tag all resources"
  type        = string
  default     = "travelmemory"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet (web server)"
  type        = string
  default     = "10.0.1.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR block for the private subnet (database server)"
  type        = string
  default     = "10.0.2.0/24"
}

variable "availability_zone" {
  description = "AZ used for both subnets (keep them in the same AZ for simplicity)"
  type        = string
  default     = "ap-south-1a"
}

variable "instance_type" {
  description = "EC2 instance type for both servers (must support AVX - MongoDB 5.0+ requires it; t2.* instances do NOT have AVX)"
  type        = string
  default     = "t3.micro"
}

variable "key_name" {
  description = "Name of an EXISTING EC2 key pair (create one in the AWS console/CLI first: aws ec2 create-key-pair --key-name travelmemory-key --query 'KeyMaterial' --output text > travelmemory-key.pem)"
  type        = string
}

variable "my_ip" {
  description = "Your public IP in CIDR form, e.g. 49.207.10.5/32. Get it with: curl -s https://checkip.amazonaws.com"
  type        = string
}

variable "db_name" {
  description = "MongoDB database name used by the app"
  type        = string
  default     = "travelmemory"
}
