// This unit test exercises our request/intent boundary. Actual CloudBase login
// is tested separately through real Auth/HTTP and browser integration.
export default {init:()=>({auth:{getSession:async()=>({data:{session:null},error:null})}})};
