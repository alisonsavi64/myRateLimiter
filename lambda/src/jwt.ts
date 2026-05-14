export interface Claims {
  sub: string;
  user_type?: string;
  role?: string;
  exp?: number;
}

export function extractClaims(authHeader: string): Claims | null {
  try {
    const token = authHeader.startsWith('Bearer ') ? authHeader.slice(7) : authHeader;
    const parts = token.split('.');
    if (parts.length !== 3) return null;
    const payload = JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8'));
    if (!payload.sub) return null;
    return payload as Claims;
  } catch {
    return null;
  }
}

export function getUserType(claims: Claims): string {
  return claims.user_type ?? claims.role ?? 'basic';
}
