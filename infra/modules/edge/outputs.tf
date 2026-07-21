output "cloudfront_domain" {
  value       = aws_cloudfront_distribution.this.domain_name
  description = "CloudFront distribution domain name - the live URL host."
}

output "spa_bucket_name" {
  value       = aws_s3_bucket.spa.id
  description = "Name of the S3 bucket serving the SPA static assets; the deploy workflow syncs the built SPA here."
}

output "distribution_id" {
  value       = aws_cloudfront_distribution.this.id
  description = "ID of the CloudFront distribution; the deploy workflow uses this to invalidate the cache after a deploy."
}
