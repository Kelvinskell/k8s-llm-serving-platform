# Interruption queue consumed by Karpenter for node drain notices.
resource "aws_sqs_queue" "karpenter_interruption" {
  name                      = "${var.cluster_name}-karpenter-interruption"
  message_retention_seconds = 300

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-karpenter-interruption"
  })
}