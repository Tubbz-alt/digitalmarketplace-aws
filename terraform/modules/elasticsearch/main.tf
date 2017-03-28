module "logs" {
  source = "../logs"

  name = "${var.name}"
  iam_role_id = "${aws_iam_role.elasticsearch.id}"
  log_retention_days = "${var.log_retention_days}"
}
