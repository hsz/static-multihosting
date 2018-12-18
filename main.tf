variable "domain" {
  type = "string"
  description = "Domain that will be assigned with the service, i.e. dev.example.com"
}

variable "rootDomain" {
  type = "string"
  description = "Root domain used in Route53, i.e. example.com"
}

variable "name" {
  type    = "string"
  default = "static-multiverse"
  description = "Service name"
}

variable "region" {
  type    = "string"
  default = "eu-central-1"
  description = "AWS Region"
}

provider "aws" {
  region = "${var.region}"
}

provider "aws" {
  alias  = "edge"
  region = "us-east-1" # Lambda@Edge has to be deployed in us-east-1 region
}

locals {
  rootDomain = "${var.rootDomain != "" ? var.rootDomain : var.domain}"
}

# Prepare Lambda@Edge function package
data "archive_file" "lambda_zip" {
  type        = "zip"
  output_path = "dist/lambda.zip"

  source {
    filename = "index.js"

    content = <<EOF
exports.handler = (event, context, callback) => {
  const request = event.Records[0].cf.request;
  const response = event.Records[0].cf.response;

  const dir = request.headers.host[0].value.replace(/\.?${var.domain}$$/, '');
  const uri = `/$${dir}/$${request.uri}`.replace('//', '/');

  console.log(JSON.stringify(request, null, 2));
  console.log('uri', uri, dir);

  callback(null, Object.assign(request, { uri }));
};
EOF
  }
}

# Create SSL certificate for our domain with its subdomain wildcard
resource "aws_acm_certificate" "default" {
  provider                  = "aws.edge"
  domain_name               = "${var.domain}"
  subject_alternative_names = ["*.${var.domain}"]
  validation_method         = "DNS"

  tags {
    Name = "${var.name}"
  }
}

# Create Route53 records for domain and wildcard
data "aws_route53_zone" "default" {
  name = "${local.rootDomain}"
}

resource "aws_route53_record" "main" {
  zone_id = "${data.aws_route53_zone.default.zone_id}"
  name    = "${var.domain}"
  type    = "A"

  alias {
    name                   = "${aws_cloudfront_distribution.default.domain_name}"
    zone_id                = "${aws_cloudfront_distribution.default.hosted_zone_id}"
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "wildcard" {
  zone_id = "${data.aws_route53_zone.default.zone_id}"
  name    = "*.${var.domain}"
  type    = "A"

  alias {
    name                   = "${aws_cloudfront_distribution.default.domain_name}"
    zone_id                = "${aws_cloudfront_distribution.default.hosted_zone_id}"
    evaluate_target_health = false
  }
}

# Create IAM Role for Lambda@Edge
resource "aws_iam_role" "default" {
  name = "${var.name}-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": [
          "lambda.amazonaws.com",
          "edgelambda.amazonaws.com"
        ]
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_policy" "default" {
  name        = "${var.name}-policy"
  path        = "/"
  description = "IAM policy for logging from a lambda"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:*:*:*",
      "Effect": "Allow"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = "${aws_iam_role.default.name}"
  policy_arn = "${aws_iam_policy.default.arn}"
}

# Create Lambda@Edge function
resource "aws_lambda_function" "default" {
  provider         = "aws.edge"
  filename         = "dist/lambda.zip"
  handler          = "index.handler"
  runtime          = "nodejs8.10"
  source_code_hash = "${data.archive_file.lambda_zip.output_base64sha256}"
  function_name    = "${var.name}"
  description      = "${var.name} Lambda@Edge function"
  role             = "${aws_iam_role.default.arn}"
  publish          = "true"
}

# Prepare S3 bucket
resource "aws_s3_bucket" "default" {
  bucket        = "${var.domain}"
  acl           = "public-read"
  force_destroy = "true"

  website {
    index_document = "index.html"
  }

  tags = {
    Name = "${var.name} bucket"
  }
}

resource "aws_s3_bucket_object" "index" {
  bucket = "${aws_s3_bucket.default.bucket}"
  key    = "index.html"
  acl    = "public-read"

  content_type = "text/html"

  content = <<EOF
<h1>${var.domain}</h1>
<p>Created with <a href="https://github.com/hsz/static-multiverse">static-multiverse</a></p>
EOF
}

# CloudFront disctibution
resource "aws_cloudfront_distribution" "default" {
  depends_on = ["aws_lambda_function.default", "aws_acm_certificate.default", "aws_s3_bucket.default"]

  origin {
    origin_id   = "${aws_s3_bucket.default.id}"
    domain_name = "${aws_s3_bucket.default.website_endpoint}"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1", "TLSv1.1", "TLSv1.2"]
    }
  }

  aliases             = ["${var.domain}", "*.${var.domain}"]
  default_root_object = "index.html"
  enabled             = true
  is_ipv6_enabled     = true

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "${var.domain}"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    lambda_function_association {
      event_type   = "viewer-request"
      lambda_arn   = "${aws_lambda_function.default.arn}:${aws_lambda_function.default.version}"
      include_body = false
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
      locations        = []
    }
  }

  viewer_certificate {
    acm_certificate_arn      = "${aws_acm_certificate.default.arn}"
    minimum_protocol_version = "TLSv1.1_2016"
    ssl_support_method       = "sni-only"
  }
}
