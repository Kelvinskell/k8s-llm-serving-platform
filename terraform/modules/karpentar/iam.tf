# IRSA trust policy for Karpenter controller service account.
data "aws_iam_policy_document" "karpenter_controller_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.cluster_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.cluster_oidc_issuer_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.cluster_oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:karpenter:karpenter"]
    }
  }
}

# IAM role assumed by the Karpenter controller via IRSA.
resource "aws_iam_role" "karpenter_controller" {
  name               = "${var.cluster_name}-karpenter-controller-role"
  assume_role_policy = data.aws_iam_policy_document.karpenter_controller_assume_role.json

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-karpenter-controller-role"
  })
}

# Permissions required for node launch/termination and interruption processing.
data "aws_iam_policy_document" "karpenter_controller" {
  statement {
    sid    = "KarpenterEC2Control"
    effect = "Allow"
    actions = [
      "ec2:CreateFleet",
      "ec2:RunInstances",
      "ec2:CreateLaunchTemplate",
      "ec2:DeleteLaunchTemplate",
      "ec2:CreateTags",
      "ec2:DeleteTags",
      "ec2:TerminateInstances",
      "ec2:DescribeImages",
      "ec2:DescribeInstances",
      "ec2:DescribeCapacityReservations",
      "ec2:DescribeInstanceStatus",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeInstanceTypeOfferings",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribePlacementGroups",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSpotPriceHistory",
      "ec2:DescribeSubnets",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeVpcs",
      "ssm:GetParameter",
      "pricing:GetProducts",
      "eks:DescribeCluster"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "KarpenterPassNodeRole"
    effect = "Allow"
    actions = [
      "iam:PassRole"
    ]
    resources = [
      var.karpenter_node_role_arn
    ]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = [
        "ec2.amazonaws.com",
        "ec2.amazonaws.com.cn"
      ]
    }
  }

  statement {
    sid    = "KarpenterInstanceProfileManagement"
    effect = "Allow"
    actions = [
      "iam:CreateInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:UntagInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:ListInstanceProfiles",
      "iam:GetRole"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "KarpenterInterruptionQueue"
    effect = "Allow"
    actions = [
      "sqs:GetQueueUrl",
      "sqs:GetQueueAttributes",
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage"
    ]
    resources = [
      aws_sqs_queue.karpenter_interruption.arn
    ]
  }
}

resource "aws_iam_policy" "karpenter_controller" {
  name   = "${var.cluster_name}-karpenter-controller-policy"
  policy = data.aws_iam_policy_document.karpenter_controller.json
}

resource "aws_iam_role_policy_attachment" "karpenter_controller" {
  role       = aws_iam_role.karpenter_controller.name
  policy_arn = aws_iam_policy.karpenter_controller.arn
}