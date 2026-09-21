// Re-enqueue all HEIC assets for thumbnail regeneration.
// Run on NAS: /var/packages/immich/target/node/bin/node regen-heic-thumbnails.cjs
const fs = require('fs');
const pg = require('/var/packages/immich/target/server/node_modules/.pnpm/pg@8.20.0/node_modules/pg');
const bullmq = require('/var/packages/immich/target/server/node_modules/bullmq');

// Read DB_PORT and REDIS_PORT from immich.conf (format: KEY=VALUE lines)
function readConf() {
  const conf = {};
  try {
    const lines = fs.readFileSync('/var/packages/immich/target/conf/immich.conf', 'utf8').split('\n');
    for (const line of lines) {
      const m = line.match(/^([A-Z_]+)=(.*)$/);
      if (m) conf[m[1]] = m[2].trim();
    }
  } catch (_) {}
  return conf;
}

async function main() {
  const conf = readConf();
  const dbPort = parseInt(conf.DB_PORT || '5433', 10);
  const redisPort = parseInt(conf.REDIS_PORT || '6379', 10);
  console.log(`Using DB port ${dbPort}, Redis port ${redisPort}`);

  const db = new pg.Client({host:'127.0.0.1',port:dbPort,user:'immich',password:'immich',database:'immich'});
  await db.connect();
  const {rowCount:del} = await db.query("DELETE FROM asset_file f USING asset a WHERE f.\"assetId\"=a.id AND a.\"originalPath\" ILIKE '%.heic' AND f.type IN ('preview','thumbnail')");
  console.log('Deleted', del, 'existing HEIC thumbnail rows');
  const {rows} = await db.query("SELECT id FROM asset WHERE \"originalPath\" ILIKE '%.heic' ORDER BY id");
  console.log('Total HEIC assets:', rows.length);
  await db.end();
  const q = new bullmq.Queue('thumbnailGeneration', {connection:{host:'127.0.0.1',port:redisPort},prefix:'immich_bull'});
  for (const r of rows) {
    await q.add('AssetGenerateThumbnails', {id:r.id}, {jobId:r.id,removeOnComplete:true,removeOnFail:false});
  }
  console.log('Enqueued', rows.length, 'HEIC assets');
  await q.close();
}
main().catch(e => { console.error(e.message); process.exit(1); });
