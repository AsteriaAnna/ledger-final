import { DomainError } from './domain.js';
import cloudbase from '@cloudbase/js-sdk';

const envId = process.env.CLOUDBASE_ENV_ID;
const apiKey = process.env.CLOUDBASE_API_KEY;

function gateway(): string {
  if (!envId || !/^[-a-z0-9]+$/.test(envId)) throw new Error('CLOUDBASE_ENV_ID is missing or invalid');
  return `https://${envId}.api.tcloudbasegateway.com`;
}

async function responseJson(response: Response): Promise<unknown> {
  const text = await response.text();
  try { return text ? JSON.parse(text) : null; } catch { return null; }
}

export async function verifyAccessToken(token: string): Promise<string> {
  if (!token || token.length > 8192) throw new DomainError(401, 'UNAUTHORIZED', '请重新登录。');
  let response: Response;
  try {
    response = await fetch(`${gateway()}/auth/v1/user/me`, {
      headers: { Authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(8000),
    });
  } catch { throw new DomainError(503, 'AUTH_UNAVAILABLE', '登录状态暂时无法验证。'); }
  if (!response.ok) throw new DomainError(401, 'UNAUTHORIZED', '请重新登录。');
  const profile = await responseJson(response);
  if (!profile || typeof profile !== 'object' || !('sub' in profile) || typeof profile.sub !== 'string' || !profile.sub) {
    throw new DomainError(503, 'AUTH_UNAVAILABLE', '登录状态暂时无法验证。');
  }
  return profile.sub;
}

export async function callRpc<T>(name: string, args: Record<string, unknown>): Promise<T> {
  try {
    return await callRpcRaw<T>(name, args);
  } catch (error) {
    // Auth is verified before an API route calls RPC. Create the business identity
    // only for a valid first login, then retry the original operation once.
    if (name === 'sl_provision_user' || !(error instanceof DomainError) || error.code !== 'USER_NOT_PROVISIONED' ||
      typeof args.p_actor_subject !== 'string') throw error;
    await callRpcRaw('sl_provision_user', {
      p_auth_subject: args.p_actor_subject, p_display_name: '星账用户',
    });
    return callRpcRaw<T>(name, args);
  }
}

async function callRpcRaw<T>(name: string, args: Record<string, unknown>): Promise<T> {
  if (!apiKey) {
    // CloudBase Run reads its own short-lived credentials from the runtime.
    // This path cannot be exercised from an unconfigured local process.
    try {
      const sdk = cloudbase.init({ env: envId!, region: 'ap-shanghai' });
      // SDK 3.10.4 runtime has PG rpc(), while its Node declaration still labels rdb() as MySqlClient.
      const pg = sdk.rdb() as unknown as { rpc: (fn: string, input: Record<string, unknown>) => Promise<{ data: unknown; error?: Error }> };
      const { data, error } = await pg.rpc(name, args);
      if (error) throw error;
      return data as T;
    } catch (error) {
      throw mapRpcError(error);
    }
  }
  let response: Response;
  try {
    response = await fetch(`${gateway()}/v1/rdb/rest/rpc/${name}`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(args), signal: AbortSignal.timeout(12000),
    });
  } catch { throw new DomainError(503, 'DATABASE_UNAVAILABLE', '暂时无法读取账本。'); }
  const result = await responseJson(response);
  if (!response.ok) {
    const message = result && typeof result === 'object' && 'message' in result ? String(result.message) : '';
    throw mapRpcError(new Error(message));
  }
  return result as T;
}

function mapRpcError(error: unknown): DomainError {
  const message = error instanceof Error ? error.message : String(error);
  if (message.includes('sl_user_not_provisioned')) return new DomainError(403, 'USER_NOT_PROVISIONED', '当前账号尚未开通星账。');
  if (message.includes('sl_account_not_found') || message.includes('sl_transaction_not_found')) return new DomainError(404, 'NOT_FOUND', '目标不存在。');
  if (message.includes('sl_insufficient_funds')) return new DomainError(409, 'INSUFFICIENT_FUNDS', '账户可用资金不足。');
  if (message.includes('sl_idempotency_conflict')) return new DomainError(409, 'IDEMPOTENCY_KEY_CONFLICT', '同一请求标识对应的内容不同。');
  if (message.includes('sl_invalid_input')) return new DomainError(422, 'VALIDATION_ERROR', '请求内容不合法。');
  return new DomainError(503, 'DATABASE_UNAVAILABLE', '暂时无法读取账本。');
}
