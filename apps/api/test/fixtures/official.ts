import ExcelJS from 'exceljs';
export const wxHeader=['交易时间','交易类型','交易对方','商品','收/支','金额(元)','支付方式','当前状态','交易单号','商户单号','备注'];
export const alipayHeader=['交易时间','交易分类','交易对方','对方账号','商品说明','收/支','金额','收/付款方式','交易状态','交易订单号','商家订单号','备注'];
export async function officialWorkbook(platform:'wechat'|'alipay',rows:string[][],options:{exported?:string;declared?:number;from?:string;to?:string;extraHeaderRows?:number}={}) {
  const w=new ExcelJS.Workbook(),s=w.addWorksheet('账单');
  s.addRow([platform==='wechat'?'微信支付账单明细':'支付宝交易记录明细']);
  s.addRow([platform==='wechat'?'微信昵称：[合成账号]':'支付宝账号：[synthetic@example.invalid]']);
  s.addRow([`起始时间：[${options.from??'2026-10-01 00:00:00'}] 终止时间：[${options.to??'2026-10-27 23:59:59'}]`]);
  s.addRow([`导出时间：[${options.exported??'2026-10-27 23:59:59'}]`]);
  s.addRow([`全部账单 共${options.declared??rows.length}笔记录`]);
  for(let i=0;i<(options.extraHeaderRows??0);i++)s.addRow(['文件说明']);
  s.addRow(platform==='wechat'?wxHeader:alipayHeader);rows.forEach(r=>s.addRow(r));
  return Buffer.from(await w.xlsx.writeBuffer());
}
export const wxRow=(id:string,kind='商户消费',direction='支出',amount='10.00',method='零钱',status='支付成功',note='',time='2026-10-10 12:00:00')=>
  [time,kind,'合成商户','合成商品',direction,amount,method,status,id,'',note];
