import { APIGatewayRequestAuthorizerEvent, APIGatewayAuthorizerResult } from 'aws-lambda';
import { extractClaims, getUserType } from './jwt';
import { check } from './ratelimit';
import { config } from './config';

export async function authorizer(event: APIGatewayRequestAuthorizerEvent): Promise<APIGatewayAuthorizerResult> {
  const authHeader = event.headers?.Authorization ?? event.headers?.authorization ?? '';
  const claims = extractClaims(authHeader);

  const userId = claims?.sub ?? `ip:${event.requestContext?.identity?.sourceIp ?? 'unknown'}`;
  const userType = claims ? getUserType(claims) : 'basic';

  if (userType === 'admin') {
    return allow(userId, { userId, userType });
  }

  const limit = userType === 'premium' ? config.rateLimitPremium : config.rateLimitBasic;
  const result = await check(userId, limit);

  const ctx: Record<string, string> = {
    rateLimitLimit: String(result.limit),
    rateLimitRemaining: String(result.remaining),
    rateLimitReset: String(result.reset),
    userId,
    userType,
  };

  return result.allowed ? allow(userId, ctx) : deny(userId, ctx);
}

function allow(principalId: string, context: Record<string, string>): APIGatewayAuthorizerResult {
  return {
    principalId,
    policyDocument: {
      Version: '2012-10-17',
      Statement: [{ Action: 'execute-api:Invoke', Effect: 'Allow', Resource: '*' }],
    },
    context,
  };
}

function deny(principalId: string, context: Record<string, string>): APIGatewayAuthorizerResult {
  return {
    principalId,
    policyDocument: {
      Version: '2012-10-17',
      Statement: [{ Action: 'execute-api:Invoke', Effect: 'Deny', Resource: '*' }],
    },
    context,
  };
}
