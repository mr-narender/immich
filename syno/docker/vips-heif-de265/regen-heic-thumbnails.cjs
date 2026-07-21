// Re-enqueue all HEIC assets for thumbnail regeneration.
// Run on NAS: /var/packages/immich/target/node/bin/node regen-heic-thumbnails.cjs
const pg = require('/var/packages/immich/target/server/node_modules/.pnpm/pg@8.20.0/node_modules/pg');
const bullmq = require('/var/packages/immich/target/server/node_modules/bullmq');
async function main() {
  const db = new pg.Client({host:'127.0.0.1',port:5434,user:'immich',password:'immich',database:'immich'});
  await db.connect();
  const {rowCount:del} = await db.query("DELETE FROM asset_file f USING asset a WHERE f.\"assetId\"=a.id AND a.\"originalPath\" ILIKE '%.heic' AND f.type IN ('preview','thumbnail')");
  console.log('Deleted', del, 'existing HEIC thumbnail rows');
  const {rows} = await db.query("SELECT id FROM asset WHERE \"originalPath\" ILIKE '%.heic' ORDER BY id");
  console.log('Total HEIC assets:', rows.length);
  await db.end();
  const q = new bullmq.Queue('thumbnailGeneration', {connection:{host:'127.0.0.1',port:6379},prefix:'immich_bull'});
  for (const r of rows) {
    await q.add('AssetGenerateThumbnails', {id:r.id}, {jobId:r.id,removeOnComplete:true,removeOnFail:false});
  }
  console.log('Enqueued', rows.length, 'HEIC assets');
  await q.close();
}
main().catch(e => { console.error(e.message); process.exit(1); });
