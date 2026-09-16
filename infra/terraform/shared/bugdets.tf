# An email when this project's spend crosses half and then all of the monthly budget.
resource "aws_budgets_budget" "monthly" {
  name         = "${local.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd) # the AWS API expects a string here
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # The account also hosts other projects, so only resources tagged project=medical-rag count.
  # In HCL "$${" is an escape sequence, so format() is the simplest way to write a literal "$".
  # This needs the "project" cost allocation tag to be activated in the billing console.
  cost_filter {
    name   = "TagKeyValue"
    values = [format("user:project$%s", var.project)]
  }

  # dynamic generates one notification block per item, here 50% and 100% of the limit.
  # ACTUAL alerts on real spend; FORECASTED would also fire on predictions and cause false alarms.
  dynamic "notification" {
    for_each = [50, 100]

    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.budget_email]
    }
  }
}
