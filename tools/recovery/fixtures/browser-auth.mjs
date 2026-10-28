// Local browser verification only. Vite aliases the SDK to this file only in
// verify-mobile.mjs; production builds never import this module.
const storage='ledger-local-browser-session';
const read=()=>JSON.parse(localStorage.getItem(storage)||'null');
export default {init:()=>({auth:{
  async getSession(){return {data:{session:read()},error:null};},
  async signInWithPassword({username,password}){
    if(!['local-only-a','local-only-b'].includes(username)||password!=='local-browser-only')
      return {data:null,error:{message:'本地验证账号或密码错误。'}};
    const session={access_token:username,user:{id:username}};
    localStorage.setItem(storage,JSON.stringify(session));return {data:{session},error:null};
  },
  async signOut(){localStorage.removeItem(storage);return {error:null};},
}})};
