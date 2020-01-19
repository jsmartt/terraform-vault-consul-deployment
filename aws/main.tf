provider "aws" {
  region = "us-east-1"
}

resource "random_id" "project_name" {
  byte_length = 4
}

# Local for tag to attach to all items
locals {
  tags = merge(
    var.tags,
    {
      "ProjectName" = random_id.project_name.hex
    },
  )
}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"
  name   = "${random_id.project_name.hex}"

  cidr = "10.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1b", "us-east-1c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    Name = "overridden-name-public"
  }

  tags = local.tags

  vpc_tags = {
    Name = "${random_id.project_name.hex}-vpc"
  }
}

# AWS S3 Bucket for Certificates, Private Keys, Encryption Key, and License
resource "aws_kms_key" "bucketkms" {
  description             = "${random_id.project_name.hex}-key"
  deletion_window_in_days = 7
  # Add deny all policy to kms key to ensure accessing secrets
  # is a break-glass proceedure
  #  policy                  = "arn:aws:iam::aws:policy/AWSDenyAll"
  lifecycle {
    create_before_destroy = true
  }
  tags = local.tags
}

resource "aws_s3_bucket" "consul_setup" {
  bucket        = "${random_id.project_name.hex}-consul-setup"
  acl           = "private"
  force_destroy = var.force_bucket_destroy
  lifecycle {
    create_before_destroy = true
  }
  tags = local.tags
}

# AWS S3 Bucket for Consul Backups
resource "aws_s3_bucket" "consul_backups" {
  count         = var.consul_ent_license != "" ? 1 : 0
  bucket        = "${random_id.project_name.hex}-consul-backups"
  lifecycle {
    create_before_destroy = true
  }
  tags = local.tags
}

# Create IAM policy to allow Consul to reach S3 bucket and KMS key
data "aws_iam_policy_document" "consul_bucket" {
  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject"
    ]
    resources = [
      "${aws_s3_bucket.consul_setup.arn}/*"
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:ListBucket"
    ]
    resources = [
      aws_s3_bucket.consul_setup.arn
    ]
  }
}

resource "aws_iam_role_policy" "consul_bucket" {
  name   = "${random_id.project_name.id}-consul-bucket"
  role   = module.consul.iam_role_id
  policy = data.aws_iam_policy_document.consul_bucket.json
}

data "aws_iam_policy_document" "bucketkms" {
  statement {
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:Encrypt",
      "kms:GenerateDataKey"
    ]
    resources = [
      "${aws_kms_key.bucketkms.arn}"
    ]
  }
}

resource "aws_iam_role_policy" "bucketkms" {
  name   = "${random_id.project_name.id}-bucketkms"
  role   = module.consul.iam_role_id
  policy = data.aws_iam_policy_document.bucketkms.json
}

# Create IAM policy to allow Consul backups to reach S3 bucket
data "aws_iam_policy_document" "consul_backups" {
  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:ListBucket",
      "s3:ListBucketVersions"
    ]
    resources = [
      "${aws_s3_bucket.consul_backups[0].arn}/*"
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:ListBucket"
    ]
    resources = [
      aws_s3_bucket.consul_backups[0].arn
    ]
  }
}

resource "aws_iam_role_policy" "consul_backups" {
  name   = "${random_id.project_name.id}-consul-backups"
  role   = module.consul.iam_role_id
  policy = data.aws_iam_policy_document.consul_backups.json
}

# Lookup most recent AMI
data "aws_ami" "latest-image" {
  most_recent = true
  owners      = var.ami_filter_owners

  filter {
    name   = "name"
    values = var.ami_filter_name
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

module "lambda" {
  source = "github.com/chrismatteson/terraform-lambda"
  function_name = "${random_id.project_name.hex}-consul-license"
  source_files = [{content="install_license.py", filename="install_license.py"}]
  environment_variables = {"LICENSE"=var.consul_ent_license} 
  handler = "install_license.lambda_handler"
  subnet_ids = module.vpc.public_subnets
  security_group_ids = [module.vpc.default_security_group_id]
}

module "consul" {
  #  source                      = "hashicorp/consul/aws"
  source                      = "github.com/hashicorp/terraform-aws-consul.git//modules/consul-cluster?ref=v0.7.1"
  ami_id                      = var.ami_id != "" ? var.ami_id : data.aws_ami.latest-image.id
  cluster_name                = random_id.project_name.hex
  cluster_size                = var.cluster_size
  instance_type               = "t2.small"
  vpc_id                      = module.vpc.vpc_id
  subnet_ids                  = module.vpc.public_subnets
  ssh_key_name                = var.ssh_key_name
  allowed_inbound_cidr_blocks = ["0.0.0.0/0"]
  allowed_ssh_cidr_blocks     = ["0.0.0.0/0"]
  enabled_metrics             = ["GroupTotalInstances"]
  tags                        = [
    for k, v in local.tags:
    {
      key: k
      value: v
      propagate_at_launch: true
    }
  ]
  user_data = templatefile("${path.module}/install-consul.tpl",
    {
      version                             = var.consul_version,
      download_url                        = var.download_url,
      path                                = var.path,
      user                                = var.user,
      ca_path                             = var.ca_path,
      cert_file_path                      = var.cert_file_path,
      key_file_path                       = var.key_file_path,
      server                              = var.server,
      client                              = var.client,
      config_dir                          = var.config_dir,
      data_dir                            = var.data_dir,
      systemd_stdout                      = var.systemd_stdout,
      systemd_stderr                      = var.systemd_stderr,
      bin_dir                             = var.bin_dir,
      cluster_tag_key                     = var.cluster_tag_key,
      cluster_tag_value                   = var.cluster_tag_value,
      datacenter                          = var.datacenter,
      autopilot_cleanup_dead_servers      = var.autopilot_cleanup_dead_servers,
      autopilot_last_contact_threshold    = var.autopilot_last_contact_threshold,
      autopilot_max_trailing_logs         = var.autopilot_max_trailing_logs,
      autopilot_server_stabilization_time = var.autopilot_server_stabilization_time,
      autopilot_redundancy_zone_tag       = var.autopilot_redundancy_zone_tag,
      autopilot_disable_upgrade_migration = var.autopilot_disable_upgrade_migration,
      autopilot_upgrade_version_tag       = var.autopilot_upgrade_version_tag,
      enable_gossip_encryption            = var.enable_gossip_encryption,
      enable_rpc_encryption               = var.enable_rpc_encryption,
      environment                         = var.environment,
      skip_consul_config                  = var.skip_consul_config,
      recursor                            = var.recursor,
      bucket                              = aws_s3_bucket.consul_setup.id,
      bucketkms                           = aws_kms_key.bucketkms.id,
      consul_license_arn                  = var.consul_ent_license != "" ? module.lambda.arn : "", 
      enable_acls                         = var.enable_acls,
      enable_consul_http_encryption       = var.enable_consul_http_encryption,
      consul_backup_bucket                = aws_s3_bucket.consul_backups[0].id,
    },
  )
}

resource "aws_iam_role_policy_attachment" "SystemsManager" {
  role = module.consul.iam_role_id
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "invoke_lambda" {
  statement {
            effect = "Allow"
            actions = ["lambda:InvokeFunction"]
            resources = [module.lambda.arn]
  }
}

resource "aws_iam_role_policy" "InvokeLambda" {
  name   = "${random_id.project_name.id}-invoke-lambda"
  role = module.consul.iam_role_id
  policy = data.aws_iam_policy_document.invoke_lambda.json
}
