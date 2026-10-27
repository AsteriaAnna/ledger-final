import { app } from './http/app.js';

const port = Number(process.env.PORT ?? 3000);
if (!process.env.CLOUDBASE_ENV_ID) {
  throw new Error('CloudBase backend configuration is incomplete');
}
app.listen(port, () => console.log(`Star Ledger API listening on ${port}`));
