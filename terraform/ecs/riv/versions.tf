terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # State is local by default (terraform.tfstate here, git-ignored).
  # To share state between speakers, see backend.tf.example.
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      environment-name = var.environment_name
      created-by       = "retail-store-sample-app"
      purpose          = "reinvent-2026-con340-demo"
    }
  }
}
