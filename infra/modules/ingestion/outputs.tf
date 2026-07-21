output "lambda_function_name" {
  value       = aws_lambda_function.ingestion.function_name
  description = "Name of the ingestion Lambda function."
}

output "lambda_function_arn" {
  value       = aws_lambda_function.ingestion.arn
  description = "ARN of the ingestion Lambda function."
}
