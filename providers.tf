terraform {
  required_version = ">= 1.3.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.85.0, < 7.0.0"
    }
  }
}

provider "aws" {
  region  = "us-west-2"
}
