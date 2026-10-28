import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { parse } from 'yaml';
import { Ajv2020 } from 'ajv/dist/2020.js';
import { DomainError } from './ledger.js';

// Runtime request validation uses the actual public contract, not a copied schema.
const document=parse(readFileSync(resolve(process.env.LEDGER_CONTRACT_PATH??'../../openapi.yaml'),'utf8'));
const ajv=new Ajv2020({strict:false,validateFormats:false});
ajv.addSchema({$id:'ledger',components:document.components});
const validators=new Map<string,ReturnType<typeof ajv.compile>>();
export function contractInput<T=Record<string,any>>(name:string,value:unknown):T {
  let check=validators.get(name);
  if(!check){check=ajv.compile({$ref:`ledger#/components/schemas/${name}`});validators.set(name,check);}
  if(!check(value))throw new DomainError(422,'VALIDATION_ERROR','内容不符合接口要求，请检查填写字段。');
  return value as T;
}
