import Redis from 'ioredis';
import { config } from './config';

let client: Redis | null = null;

function getRedis(): Redis {
  if (!client) {
    client = new Redis({ host: config.redisHost, port: config.redisPort });
    client.on('error', () => { /* fail-open: errors handled per-call */ });
  }
  return client;
}

export interface RateLimitResult {
  allowed: boolean;
  limit: number;
  remaining: number;
  reset: number;
}

export async function check(userID: string, limit: number): Promise<RateLimitResult> {
  const now = Date.now();
  const windowMs = 60_000;
  const key = `rl:user:${userID}`;
  const reset = Math.ceil((now + windowMs) / 1000);

  try {
    const redis = getRedis();
    const pipe = redis.pipeline();
    pipe.zadd(key, now, String(now));
    pipe.zremrangebyscore(key, '-inf', now - windowMs);
    pipe.zcard(key);
    pipe.expire(key, 61);
    const results = await pipe.exec();
    const count = (results?.[2]?.[1] as number) ?? 1;
    return { allowed: count <= limit, limit, remaining: Math.max(0, limit - count), reset };
  } catch {
    return { allowed: true, limit, remaining: limit - 1, reset };
  }
}
