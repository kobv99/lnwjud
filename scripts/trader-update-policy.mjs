import { DatabaseSync } from 'node:sqlite';

function arg(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

const dbPath = arg('--db');
const intervalRaw = arg('--interval-minutes') ?? '30';
if (!dbPath) {
  console.error('Missing --db <path>');
  process.exit(2);
}
const interval = Number.parseInt(intervalRaw, 10);
if (!Number.isInteger(interval) || interval < 5 || interval > 1440) {
  console.error('Invalid --interval-minutes; expected integer 5..1440');
  process.exit(2);
}

const db = new DatabaseSync(dbPath);
try {
  db.exec('BEGIN IMMEDIATE');
  const upsert = db.prepare(`
    INSERT INTO settings(key, value) VALUES(?, ?)
    ON CONFLICT(key) DO UPDATE SET value = excluded.value
  `);
  upsert.run('update_auto_check', 'true');
  upsert.run('update_check_on_startup', 'true');
  upsert.run('update_interval_minutes', String(interval));
  upsert.run('update_auto_download', 'false');
  db.exec('COMMIT');

  const rows = db.prepare(`
    SELECT key, value
    FROM settings
    WHERE key IN (
      'update_auto_check',
      'update_check_on_startup',
      'update_interval_minutes',
      'update_auto_download'
    )
    ORDER BY key
  `).all();

  const expected = new Map([
    ['update_auto_check', 'true'],
    ['update_check_on_startup', 'true'],
    ['update_interval_minutes', String(interval)],
    ['update_auto_download', 'false'],
  ]);

  for (const row of rows) {
    if (expected.get(row.key) !== row.value) {
      throw new Error(`Unexpected persisted update policy for ${row.key}: ${row.value}`);
    }
    expected.delete(row.key);
  }
  if (expected.size !== 0) {
    throw new Error(`Missing persisted update policy keys: ${[...expected.keys()].join(', ')}`);
  }

  console.log('TRADER_UPDATE_POLICY=PASS');
  console.log('UPDATE_AUTO_CHECK=true');
  console.log('UPDATE_CHECK_ON_STARTUP=true');
  console.log(`UPDATE_INTERVAL_MINUTES=${interval}`);
  console.log('UPDATE_AUTO_DOWNLOAD=false');
} catch (error) {
  try {
    db.exec('ROLLBACK');
  } catch {}
  console.error(error instanceof Error ? error.stack ?? error.message : String(error));
  process.exitCode = 1;
} finally {
  db.close();
}
