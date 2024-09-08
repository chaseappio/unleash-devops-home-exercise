terraform {
 required_providers {
   aws = {
     source  = "hashicorp/aws"
     version = "~> 3.0"
   }
 }
}

provider "aws" {
 region = "us-west-2"
}

variable "aws_account_id" {
  type = string
  default = "905418187602"
}

// EKS
data "aws_vpc" "default_vpc" {
  id = "vpc-0b476b3f6f33d2df7"
}

data "aws_subnets" "default_subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default_vpc.id]
  }
}

data "aws_security_group" "default_sg" {
  id = "sg-079319ca70edbd33d"
}


resource "aws_iam_role" "eks_cluster_role" {
  name = "EKSClusterRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
      },
    ]
  })
}


resource "aws_iam_role" "node_group_role" {
  name = "EKSNodeGroupRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "amazon_eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster_role.name
}

resource "aws_iam_role_policy_attachment" "amazon_eks_worker_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.node_group_role.name
}

resource "aws_iam_role_policy_attachment" "amazon_ecr_read_only" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.node_group_role.name
}

resource "aws_iam_role_policy_attachment" "amazon_eks_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.node_group_role.name
}

resource "aws_eks_cluster" "eks_cluster" {
  name     = "application-cluster"
  role_arn = aws_iam_role.eks_cluster_role.arn
  version  = "1.30"

  vpc_config {
    subnet_ids          = flatten([ data.aws_subnets.default_subnets.ids ])
  }

  depends_on = [
    aws_iam_role_policy_attachment.amazon_eks_cluster_policy
  ]
}

resource "aws_eks_node_group" "node_ec2" {
  cluster_name    = aws_eks_cluster.eks_cluster.name
  node_group_name = "application-node-group"
  node_role_arn   = aws_iam_role.node_group_role.arn
  subnet_ids      = flatten( data.aws_subnets.default_subnets.ids )

  scaling_config {
    desired_size = 2
    max_size     = 7
    min_size     = 1
  }

  ami_type       = "AL2_x86_64"
  instance_types = ["t3.large"]
  capacity_type  = "ON_DEMAND"
  disk_size      = 20

  depends_on = [
    aws_iam_role_policy_attachment.amazon_eks_worker_policy,
    aws_iam_role_policy_attachment.amazon_ecr_read_only,
    aws_iam_role_policy_attachment.amazon_eks_cni_policy
  ]
}

// S3
variable "bucket_name" {
  type = string
}


resource "aws_s3_bucket" "application_bucket" {
 bucket = var.bucket_name
 acl    = "private"

 versioning {
   enabled = true
 }

 server_side_encryption_configuration {
   rule {
     apply_server_side_encryption_by_default {
       kms_master_key_id = aws_kms_key.terraform-bucket-key.arn
       sse_algorithm     = "aws:kms"
     }
   }
 }
}

resource "aws_s3_bucket_public_access_block" "access" {
 bucket = aws_s3_bucket.application_bucket.id

 block_public_acls       = true
 block_public_policy     = true
 ignore_public_acls      = true
 restrict_public_buckets = true
}

// Secret-manager
variable "aws_access_key" {
  type = string
}

variable "aws_secret_key" {
  type = string
}

resource "aws_secretsmanager_secret" "application_credentials" {
  name        = "application-credentials"
  description = "This is a secret that store application credntials"
}

resource "aws_secretsmanager_secret_version" "example_version" {
  secret_id     = aws_secretsmanager_secret.application_credentials.id
  secret_string = jsonencode({
    access_key = var.aws_access_key
    secret_key = var.aws_secret_key
    bucket     = var.bucket_name
  })
}

// External Secret Operator

data "tls_certificate" "demo_cluster_certificate" {
  url = aws_eks_cluster.eks_cluster.identity[0].oidc[0].issuer
}

locals {
  eks_oidc_provider = replace(aws_eks_cluster.eks_cluster.identity[0].oidc[0].issuer, "https://", "")
}
resource "aws_iam_openid_connect_provider" "oidc_provider" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.demo_cluster_certificate.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.eks_cluster.identity[0].oidc[0].issuer
}

resource "aws_iam_role" "secret_manager_role" {
  name = "eso-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
     {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${var.aws_account_id}:oidc-provider/${local.eks_oidc_provider}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${local.eks_oidc_provider}:aud": "sts.amazonaws.com",
          "${local.eks_oidc_provider}:sub": "system:serviceaccount:default:eso-serviceaccount"
        }
      }
    }
    ]
  })
}

resource "aws_iam_policy" "secret_manager_policy" {
  name        = "eso-policy"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = [
          "secretsmanager:GetResourcePolicy",
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecretVersionIds"
        ],
        Resource = [
          "*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "secret_manager_policy_attachment" {
  role       = aws_iam_role.secret_manager_role.name
  policy_arn  = aws_iam_policy.secret_manager_policy.arn
}

