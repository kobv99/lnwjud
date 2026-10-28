import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { windowsContainedProcessSource } from './windows-contained-process.js';

export interface WindowsContainedLaunch {
  readonly executable: string;
  readonly args: readonly string[];
  readonly receiptPath: string;
  readonly cancelPath: string;
}

export interface WindowsContainmentReceipt {
  readonly kind: 'windows_job_v1';
  readonly outcome: 'completed' | 'cancelled' | 'timed_out';
  readonly exitCode: number;
  readonly activeProcesses: 0;
}

export async function prepareWindowsContainedLaunch(input: {
  readonly directory: string;
  readonly executable: string;
  readonly args: readonly string[];
  readonly cwd: string;
  readonly timeoutMs: number;
  readonly windowsVerbatimArguments?: boolean;
}): Promise<WindowsContainedLaunch> {
  if (process.platform !== 'win32') throw new Error('WINDOWS_CONTAINMENT_UNSUPPORTED');
  if (![input.directory, input.executable, input.cwd].every((value) => path.isAbsolute(value))) throw new Error('WINDOWS_CONTAINMENT_ABSOLUTE_PATH_REQUIRED');
  await mkdir(input.directory, { recursive: true, mode: 0o700 });
  const sourcePath = path.join(input.directory, 'containment.cs');
  const specPath = path.join(input.directory, 'containment.json');
  const receiptPath = path.join(input.directory, 'containment.receipt.json');
  const cancelPath = path.join(input.directory, 'containment.cancel');
  await writeFile(sourcePath, windowsContainedProcessSource, { flag: 'wx', mode: 0o600 });
  await writeFile(specPath, JSON.stringify({ executable: input.executable, arguments: input.args, cwd: input.cwd, timeoutMs: input.timeoutMs, windowsVerbatimArguments: input.windowsVerbatimArguments === true }), { flag: 'wx', mode: 0o600 });
  const systemRoot = process.env.SystemRoot;
  if (systemRoot === undefined || !path.isAbsolute(systemRoot)) throw new Error('WINDOWS_CONTAINMENT_HOST_UNAVAILABLE');
  const directoryToken = Buffer.from(input.directory, 'utf8').toString('base64');
  const command = `$Directory=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${directoryToken}'))\n${containedLaunchCommand}`;
  return {
    executable: path.join(systemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'),
    args: ['-NoProfile', '-NonInteractive', '-Command', command],
    receiptPath,
    cancelPath,
  };
}

export async function readWindowsContainmentReceipt(filename: string): Promise<WindowsContainmentReceipt | undefined> {
  try {
    const parsed: unknown = JSON.parse(await readFile(filename, 'utf8'));
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) return undefined;
    if (!('kind' in parsed) || parsed.kind !== 'windows_job_v1'
      || !('activeProcesses' in parsed) || parsed.activeProcesses !== 0
      || !('outcome' in parsed) || (parsed.outcome !== 'completed' && parsed.outcome !== 'cancelled' && parsed.outcome !== 'timed_out')
      || !('exitCode' in parsed) || typeof parsed.exitCode !== 'number' || !Number.isInteger(parsed.exitCode)) return undefined;
    return { kind: parsed.kind, activeProcesses: 0, outcome: parsed.outcome, exitCode: parsed.exitCode };
  } catch { return undefined; }
}

const containedLaunchCommand = String.raw`$ErrorActionPreference='Stop'
$job=$null
try {
 Add-Type -Path (Join-Path $Directory 'containment.cs')
 $spec=Get-Content -LiteralPath (Join-Path $Directory 'containment.json') -Raw | ConvertFrom-Json
 $job=[ContainedProcess]::Start([string]$spec.executable,[string[]]@($spec.arguments),[string]$spec.cwd,[bool]$spec.windowsVerbatimArguments)
 $end=[DateTime]::UtcNow.AddMilliseconds([double]$spec.timeoutMs)
 $outcome='completed'
 while($true) {
  if([IO.File]::Exists((Join-Path $Directory 'containment.cancel'))) {$outcome='cancelled';$job.Cancel();break}
  if([DateTime]::UtcNow -ge $end) {$outcome='timed_out';$job.Cancel();break}
  try {$exitCode=$job.WaitForExit(100);break} catch {
   if($_.Exception.InnerException -isnot [TimeoutException]) {throw}
  }
 }
 if($outcome -ne 'completed') {$exitCode=1}
 if($job.ActiveProcesses -ne 0) {throw 'CONTAINMENT_UNVERIFIED'}
 $receipt=@{kind='windows_job_v1';outcome=$outcome;exitCode=$exitCode;activeProcesses=0} | ConvertTo-Json -Compress
 $temporary=Join-Path $Directory 'containment.receipt.tmp'
 [IO.File]::WriteAllText($temporary,$receipt,(New-Object Text.UTF8Encoding($false)))
 [IO.File]::Move($temporary,(Join-Path $Directory 'containment.receipt.json'))
 exit $exitCode
} catch {
 [Console]::Error.WriteLine('CONTAINMENT_UNRESOLVED')
 exit 125
} finally {
 if($null -ne $job) {$job.Dispose()}
}
`;
