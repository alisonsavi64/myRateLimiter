resource "aws_api_gateway_rest_api" "main" {
  name = "${var.app_name}-${var.env}"

  tags = {
    Environment = var.env
  }
}

resource "aws_api_gateway_authorizer" "rate_limiter" {
  name                             = "rate-limiter"
  rest_api_id                      = aws_api_gateway_rest_api.main.id
  authorizer_uri                   = aws_lambda_function.rate_limiter.invoke_arn
  type                             = "REQUEST"
  identity_source                  = "method.request.header.Authorization"
  authorizer_result_ttl_in_seconds = 300
}

resource "aws_lambda_permission" "api_gateway_invoke" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rate_limiter.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.main.execution_arn}/*"
}

# When the authorizer denies, API GW normally returns 403.
# This gateway response remaps ACCESS_DENIED to 429 and injects X-RateLimit-* headers
# using context variables populated by the Lambda authorizer.
resource "aws_api_gateway_gateway_response" "rate_limited" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  response_type = "ACCESS_DENIED"
  status_code   = "429"

  response_parameters = {
    "gatewayresponse.header.X-RateLimit-Limit"     = "context.authorizer.rateLimitLimit"
    "gatewayresponse.header.X-RateLimit-Remaining" = "context.authorizer.rateLimitRemaining"
    "gatewayresponse.header.X-RateLimit-Reset"     = "context.authorizer.rateLimitReset"
    "gatewayresponse.header.Retry-After"           = "'60'"
    "gatewayresponse.header.Content-Type"          = "'application/json'"
  }

  response_templates = {
    "application/json" = "{\"error\": \"rate limit exceeded\", \"retry_after\": 60}"
  }
}

resource "aws_api_gateway_gateway_response" "unauthorized" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  response_type = "UNAUTHORIZED"
  status_code   = "401"

  response_parameters = {
    "gatewayresponse.header.Content-Type" = "'application/json'"
  }

  response_templates = {
    "application/json" = "{\"error\": \"unauthorized\"}"
  }
}

resource "aws_api_gateway_deployment" "main" {
  rest_api_id = aws_api_gateway_rest_api.main.id

  depends_on = [aws_api_gateway_authorizer.rate_limiter]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "main" {
  deployment_id = aws_api_gateway_deployment.main.id
  rest_api_id   = aws_api_gateway_rest_api.main.id
  stage_name    = var.env

  tags = {
    Environment = var.env
  }
}

output "api_gateway_url" {
  value = aws_api_gateway_stage.main.invoke_url
}

output "authorizer_id" {
  value = aws_api_gateway_authorizer.rate_limiter.id
}
