terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Optional: uncomment and configure to keep state off your laptop
  # backend "s3" {
  #   bucket = "your-terraform-state-bucket"
  #   key    = "travelmemory/terraform.tfstate"
  #   region = "ap-south-1"
  # }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}
