import { DomainError } from '../domain/ledger.js';
import cloudbase from '@cloudbase/js-sdk';

const envId = process.env.CLOUDBASE_ENV_ID;
const apiKey = process.env.CLOUDBASE_API_KEY;
class ProvisioningRequired extends Error {}

function gateway(): string {
  if (!envId || !/^[-a-z0-9]+$/.test(envId)) throw new Error('CLOUDBASE_ENV_ID is missing or invalid');
  return `https://${envId}.api.tcloudbasegateway.com`;
}

async function responseJson(response: Response): Promise<unknown> {
  const text = await response.text();
  try { return text ? JSON.parse(text) : null; } catch { return null; }
}

export async function verifyAccessToken(token: string): Promise<{ subject: string; displayName: string }> {
  if (!token || token.length > 8192) throw new DomainError(401, 'UNAUTHENTICATED', '请重新登录。');
  let response: Response;
  try {
    response = await fetch(`${gateway()}/auth/v1/user/me`, {
      headers: { Authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(8000),
    });
  } catch { throw new DomainError(500, 'INTERNAL_ERROR', '登录状态暂时无法验证。'); }
  if (!response.ok) throw new DomainError(401, 'UNAUTHENTICATED', '请重新登录。');
  const profile = await responseJson(response);
  if (!profile || typeof profile !== 'object' || !('sub' in profile) || typeof profile.sub !== 'string' || !profile.sub) {
    throw new DomainError(500, 'INTERNAL_ERROR', '登录状态暂时无法验证。');
  }
  const name = ('name' in profile && typeof profile.name === 'string' && profile.name.trim()) ||
    ('username' in profile && typeof profile.username === 'string' && profile.username.trim()) || '星账用户';
  return { subject: profile.sub, displayName: name.slice(0, 48) };
}

export async function callRpc<T>(name: string, args: Record<string, unknown>, displayName?: string): Promise<T> {
  try {
    return await callRpcRaw<T>(name, args);
  } catch (error) {
    const subject=args.p_actor_subject??args.p_subject;
    if (name === 'sl_provision_user' || !(error instanceof ProvisioningRequired) ||
      typeof subject !== 'string') throw error;
    // A fresh authenticated identity has an empty ledger. GET must not create it.
    if (name === 'sl_get_relationship') return {
      status: 'unbound', partner: null, permissions: { partner_accounts: 'none', partner_transactions: 'none' },
    } as T;
    if (name === 'sl_list_accounts_visible' || name === 'sl_list_transactions_visible') {
      if (args.p_view === 'partner') throw new DomainError(403, 'FORBIDDEN', '当前无法查看对象账本。');
      return [] as T;
    }
    if(name==='sl_accounts_page'||name==='sl_transactions_page'){
      if(args.p_view==='partner')throw new DomainError(403,'FORBIDDEN','当前无法查看对象账本。');
      return {data:[],next:null} as T;
    }
    if (name === 'sl_get_account_visible' || name === 'sl_get_transaction_visible' || name==='sl_import_json') {
      throw new DomainError(404, 'RESOURCE_NOT_FOUND', '目标不存在。');
    }
    // Only the first write provisions a business identity, then retries once.
    await callRpcRaw('sl_provision_user', {
      p_auth_subject: subject, p_display_name: displayName || '星账用户',
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
  } catch { throw new DomainError(500, 'INTERNAL_ERROR', '暂时无法读取账本。'); }
  const result = await responseJson(response);
  if (!response.ok) {
    const message = result && typeof result === 'object' && 'message' in result ? String(result.message) : '';
    throw mapRpcError(new Error(message));
  }
  return result as T;
}

function mapRpcError(error: unknown): Error {
  const message = error instanceof Error ? error.message : String(error);
  if (message.includes('sl_user_not_provisioned')) return new ProvisioningRequired('Business identity is not provisioned');
  if (message.includes('sl_account_not_found') || message.includes('sl_transaction_not_found')) return new DomainError(404, 'RESOURCE_NOT_FOUND', '目标不存在。');
  if (message.includes('sl_insufficient_funds')) return new DomainError(409, 'FUNDS_ALLOCATION_NOT_POSSIBLE', '账户可用资金不足。');
  if (message.includes('sl_idempotency_conflict')) return new DomainError(409, 'IDEMPOTENCY_KEY_CONFLICT', '同一请求标识对应的内容不同。');
  if (message.includes('sl_relationship_conflict')) return new DomainError(409, 'RELATIONSHIP_CONFLICT', '当前绑定状态已改变。');
  if (message.includes('sl_binding_invitation_invalid')) return new DomainError(422, 'BINDING_INVITATION_INVALID', '绑定凭据无效或已过期。');
  if (message.includes('sl_partner_unavailable')) return new DomainError(403, 'FORBIDDEN', '当前无法查看对象账本。');
  if (message.includes('sl_version_mismatch')) return new DomainError(412, 'RESOURCE_VERSION_CONFLICT', '内容已变化，请刷新后重做。');
  if (message.includes('sl_resource_conflict')) return new DomainError(409, 'RESOURCE_VERSION_CONFLICT', '内容已变化，请刷新后重做。');
  if (message.includes('sl_opening_recalculation_conflict')) return new DomainError(409, 'OPENING_STATE_RECALCULATION_CONFLICT', '无法按这些初始份额和日期安全重建，请检查后重试。原记录未改动。');
  if (message.includes('sl_unsafe_reversal')) return new DomainError(409, 'FUNDS_ALLOCATION_NOT_POSSIBLE', '这笔账的资金已被使用，无法安全撤销。');
  if (message.includes('sl_invalid_input')) return new DomainError(422, 'VALIDATION_ERROR', '请求内容不合法。');
  return new DomainError(500, 'INTERNAL_ERROR', '暂时无法读取账本。');
}
