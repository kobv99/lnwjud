import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, readdir, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import { prepareWindowsContainedLaunch, readWindowsContainmentReceipt } from './windows-contained-launch.js';

describe.skipIf(process.platform !== 'win32')('contained launch receipt', () => {
  it('works with Restricted process policy without emitting or bypassing a PowerShell script file', async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), 'lnwjud job restricted '));
    try {
      const invocation = await prepareWindowsContainedLaunch({
        directory: root, executable: process.execPath, cwd: root, timeoutMs: 10000,
        args: ['-e', 'console.log("RESTRICTED_POLICY_OUTPUT")'],
      });
      expect(invocation.args).toContain('-Command');
      expect(invocation.args).not.toContain('-File');
      expect(invocation.args).not.toContain('-ExecutionPolicy');
      expect(await readdir(root)).not.toContain('containment.ps1');

      const child = spawn(invocation.executable, [...invocation.args], {
        windowsHide: true,
        env: { ...process.env, PSExecutionPolicyPreference: 'Restricted' },
      });
      let stdout = '';
      child.stdout.on('data', (data: Buffer) => { stdout += data.toString(); });
      await once(child, 'close');

      expect(stdout).toContain('RESTRICTED_POLICY_OUTPUT');
      expect(await readWindowsContainmentReceipt(invocation.receiptPath)).toMatchObject({
        kind: 'windows_job_v1', outcome: 'completed', exitCode: 0, activeProcesses: 0,
      });
    } finally { await rm(root, { recursive: true, force: true }); }
  }, 20000);

  it.each(['completed', 'cancelled'] as const)('publishes verified %s receipt and forwards child output', async (outcome) => {
    const root = await mkdtemp(path.join(os.tmpdir(), 'lnwjud job receipt '));
    try {
      const invocation = await prepareWindowsContainedLaunch({
        directory: root, executable: process.execPath, cwd: root, timeoutMs: 10000,
        args: ['-e', outcome === 'completed' ? 'console.log("CHILD_OUTPUT")' : 'console.log("CHILD_OUTPUT");setInterval(()=>{},1000)'],
      });
      const child = spawn(invocation.executable, [...invocation.args], { windowsHide: true });
      const closed = once(child, 'close');
      let stdout = '';
      child.stdout.on('data', (data: Buffer) => { stdout += data.toString(); });
      if (outcome === 'cancelled') await writeFile(invocation.cancelPath, 'cancel');
      await closed;
      expect(await readWindowsContainmentReceipt(invocation.receiptPath)).toMatchObject({ kind: 'windows_job_v1', outcome, activeProcesses: 0 });
      if (outcome === 'completed') expect(stdout).toContain('CHILD_OUTPUT');
    } finally { await rm(root, { recursive: true, force: true }); }
  }, 20000);
});
