export const money = (minor: number) => {
  if(!Number.isSafeInteger(minor))return '金额超出显示范围';
  const n=BigInt(minor),a=n<0n?-n:n;
  return `${n<0n?'-':''}¥${a/100n}.${String(a%100n).padStart(2,'0')}`;
};

export function minorInput(value: number): string {
  if (!Number.isSafeInteger(value) || value < 0) throw new Error('金额不合法。');
  const cents = BigInt(value);
  return `${cents / 100n}.${String(cents % 100n).padStart(2, '0')}`;
}

export function minor(value: string): number {
  if (!/^\d+(?:\.\d{1,2})?$/.test(value)) throw new Error('金额请输入最多两位小数。');
  const [yuan, fen = ''] = value.split('.');
  const cents = Number(`${yuan}${fen.padEnd(2, '0')}`);
  if (!Number.isSafeInteger(cents)) throw new Error('金额过大。');
  return cents;
}

export function todayShanghai(): string {
  const parts = new Intl.DateTimeFormat('en-US', { timeZone: 'Asia/Shanghai', year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(new Date());
  const value = Object.fromEntries(parts.map(({ type, value }) => [type, value]));
  return `${value.year}-${value.month}-${value.day}`;
}

export function nowShanghai(): string {
  return new Date(Date.now() + 8 * 60 * 60 * 1000).toISOString().slice(0, 16);
}
