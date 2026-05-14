export const config = {
  redisHost: process.env.REDIS_HOST ?? 'localhost',
  redisPort: parseInt(process.env.REDIS_PORT ?? '6379', 10),
  rateLimitBasic: parseInt(process.env.RATE_LIMIT_BASIC ?? '60', 10),
  rateLimitPremium: parseInt(process.env.RATE_LIMIT_PREMIUM ?? '600', 10),
};
