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
export function contractQuery<T=Record<string,any>>(operationId:string,input:Record<string,unknown>):T {
  const cacheKey='query:'+operationId;
  let check=validators.get(cacheKey);
  if(!check){
    const operation=Object.values(document.paths).flatMap((path:any)=>Object.values(path)).find((op:any)=>op?.operationId===operationId) as any;
    if(!operation)throw new Error('Unknown contract operation');
    const parameters=(operation.parameters??[]).map((p:any)=>p.$ref?document.components.parameters[p.$ref.split('/').at(-1)]:p).filter((p:any)=>p.in==='query');
    check=ajv.compile({components:document.components,type:'object',properties:Object.fromEntries(parameters.map((p:any)=>[p.name,p.schema])),
      required:parameters.filter((p:any)=>p.required).map((p:any)=>p.name),additionalProperties:false});validators.set(cacheKey,check);
  }
  if(!check(input))throw new DomainError(422,'VALIDATION_ERROR','查询参数不合法。');
  return input as T;
}
