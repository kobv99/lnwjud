import { mkdir, mkdtemp, readFile, readdir, realpath, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { SqliteDatabase, SqliteSettingsRepository, SqliteWorkspaceRepository } from '@lnwjud/storage';
import { permissionProfiles } from '@lnwjud/permissions';
import { CAPABILITY_TASK_OWNER_METADATA_KEY } from '@lnwjud/capabilities';
import { STDIO_ALLOWED_ROOTS_SETTING_KEY, STDIO_PERMISSION_PROFILE_SETTING_KEY, STDIO_STRICT_ROOTS_SETTING_KEY, UNRESTRICTED_SETTING_KEY, USER_SETTING_KEYS, serializeToolAvailabilitySnapshot } from '@lnwjud/shared';
import { createStdioMcpRuntime } from './stdio-mcp-runtime.js';
import { sharedActivityLeaseDirectoryPath, ToolRegistry } from '@lnwjud/mcp-server';

const temporaryRoots: string[] = [];
const TEST_CHECKPOINT_KEY = Buffer.alloc(32, 0x46).toString('base64');

const workspace = {
  id: 'workspace-1',
  displayName: 'fixture',
  rootPath: 'E:\fixture',
  realRootPath: 'E:\fixture',
  createdAt: '2026-08-10T00:00:00.000Z',
};

async function waitUntil(predicate: () => boolean, timeoutMs: number = 2_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error('Timed out waiting for cross-process tool availability refresh');
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
}

beforeEach(() => {
  process.env.LNWJUD_CHECKPOINT_KEY_BASE64 = TEST_CHECKPOINT_KEY;
});

afterEach(async () => {
  delete process.env.TUNNEL_CLIENT_PROFILE_DIR;
  delete process.env.LNWJUD_CHECKPOINT_KEY_BASE64;
  await Promise.all(temporaryRoots.splice(0).map((root) => rm(root, {
    recursive: true,
    force: true,
    maxRetries: process.platform === 'win32' ? 5 : 0,
    retryDelay: 100,
  })));
});

describe('stdio MCP runtime', () => {
  it('defaults Ponytail to OFF and loads a persisted mode for direct STDIO', async () => {
    const defaultDataPath = await mkdtemp(path.join(os.tmpdir(), 'lnwjud-stdio-ponytail-default-'));
    const persistedDataPath = await mkdtemp(path.join(os.tmpdir(), 'lnwjud-stdio-ponytail-persisted-'));
    temporaryRoots.push(defaultDataPath, persistedDataPath);

    const defaultRuntime = createStdioMcpRuntime(defaultDataPath, workspace);
    try {
      expect(defaultRuntime.ponytailMode).toBe('off');
    } finally {
      await defaultRuntime.close();
    }

    const database = new SqliteDatabase(path.join(persistedDataPath, 'lnwjud.sqlite'));
    new SqliteSettingsRepository(database).set(USER_SETTING_KEYS.ponytailMode, 'ultra');
    database.close();

    const persistedRuntime = createStdioMcpRuntime(persistedDataPath, workspace);
    try {
      expect(persistedRuntime.ponytailMode).toBe('ultra');
    } finally {
      await persistedRuntime.close();
    }
  }, 15_000);

  it('wires durable goals and scheduled continuation orchestration from the same SQLite repository', async () => {
    const dataPath = await mkdtemp(path.join(os.tmpdir(), 'lnwjud-stdio-continuation-'));
    temporaryRoots.push(dataPath);
    const runtime = createStdioMcpRuntime(dataPath, workspace);
    try {
      expect(runtime.services.goals).toBeDefined();
      expect(runtime.services.scheduledContinuations).toBeDefined();
      expect(runtime.services.automationFactory).toBeDefined();
    } finally {
      await runtime.close();
    }
  });

  it('routes explicit skill discovery to the requested registered workspace while preserving the default workspace', async () => {
    const dataPath = await mkdtemp(path.join(os.tmpdir(), 'lnwjud-stdio-skill-routing-data-'));
    const workspaceRootA = await realpath(await mkdtemp(path.join(os.tmpdir(), 'lnwjud-stdio-skill-routing-a-')));
    const workspaceRootB = await realpath(await mkdtemp(path.join(os.tmpdir(), 'lnwjud-stdio-skill-routing-b-')));
    temporaryRoots.push(dataPath, workspaceRootA, workspaceRootB);
    const workspaceA = {
      id: 'stdio-workspace-a',
      displayName: 'stdio workspace A',
      rootPath: workspaceRootA,
      realRootPath: workspaceRootA,
      createdAt: '2026-09-23T00:00:00.000Z',
    };
    const workspaceB = {
      id: 'stdio-workspace-b',
      displayName: 'stdio workspace B',
      rootPath: workspaceRootB,
      realRootPath: workspaceRootB,
      createdAt: '2026-09-23T00:00:01.000Z',
    };
    for (const [workspaceRoot, name] of [
      [workspaceRootA, 'stdio-a-skill'],
      [workspaceRootB, 'stdio-b-skill'],
    ] as const) {
      const skillDir = path.join(workspaceRoot, '.agents', 'skills', name);
      await mkdir(skillDir, { recursive: true });
      await writeFile(path.join(skillDir, 'SKILL.md'), `---\nname: ${name}\ndescription: workspace skill ${name}\n---\n# ${name}\n`, 'utf8');
    }

    const seeded = new SqliteDatabase(path.join(dataPath, 'lnwjud.sqlite'));
    const repository = new SqliteWorkspaceRepository(seeded);
    await repository.insert(workspaceA);
    await repository.insert(workspaceB);
    seeded.close();

    const runtime = createStdioMcpRuntime(dataPath, workspaceA);
    try {
      const registry = new ToolRegistry(runtime.services, runtime.actor);
      const legacy = await registry.invoke('skills_list', { query: 'stdio-' });
      expect(legacy.isError).not.toBe(true);
      const legacySkills = (legacy.structuredContent as { skills?: readonly { name?: string }[] } | undefined)?.skills ?? [];
      expect(legacySkills.map((skill) => skill.name)).toContain('stdio-a-skill');
      expect(legacySkills.map((skill) => skill.name)).not.toContain('stdio-b-skill');

      const explicit = await registry.invoke('skills_list', { query: 'stdio-', workspaceId: workspaceB.id });
      expect(explicit.isError).not.toBe(true);
      const explicitSkills = (explicit.structuredContent as { skills?: readonly { name?: string }[] } | undefined)?.skills ?? [];
      expect(explicitSkills.map((skill) => skill.name)).toContain('stdio-b-skill');
      expect(explicitSkills.map((skill) => skill.name)).not.toContain('stdio-a-skill');
    } finally {
      await runtime.close();
    }
  });

  it('persists and completes a verified automation run across a STDIO runtime replacement without creating a schedule', async () => {
    const dataPath = await mkdtemp(path.join(os.tmpdir(), 'lnwjud-stdio-automation-data-'));
    const workspaceRoot = await realpath(await mkdtemp(path.join(os.tmpdir(), 'lnwjud-stdio-automation-workspace-')));
    temporaryRoots.push(dataPath, workspaceRoot);
    const durableWorkspace = {
      id: 'automation-workspace',
      displayName: 'automation workspace',
      rootPath: workspaceRoot,
      realRootPath: workspaceRoot,
      createdAt: '2026-09-20T00:00:00.000Z',
    };
    const seeded = new SqliteDatabase(path.join(dataPath, 'lnwjud.sqlite'));
    await new SqliteWorkspaceRepository(seeded).insert(durableWorkspace);
    seeded.close();

    const first = createStdioMcpRuntime(dataPath, durableWorkspace, true, { fullBypassAll: true });
    const started = await first.services.goals?.runGoal(first.actor, {
      workspaceId: durableWorkspace.id,
      goalKey: 'stdio-automation-restart',
      objective: 'Complete one verified durable automation milestone.',
      plan: { steps: [{ id: 'build', title: 'Build' }] },
      leaseSeconds: 600,
    });
    expect(started).toMatchObject({ ok: true, value: { acquired: true, leaseToken: expect.any(String) } });
    if (started === undefined || !started.ok || started.value.leaseToken === undefined) {
      await first.close();
      return;
    }
    const proof = {
      goalId: started.value.goalId,
      leaseToken: started.value.leaseToken,
      leaseGeneration: started.value.leaseGeneration,
    };
    const options = {
      authorizationModeProvider: () => 'full_bypass' as const,
      activeWorkspaceScopeProvider: async (): Promise<{ workspaceId: string; rootPath: string }> => ({ workspaceId: durableWorkspace.id, rootPath: workspaceRoot }),
    };
    const firstRegistry = new ToolRegistry(first.services, first.actor, options);
    const created = await firstRegistry.invoke('automation_create', {
      workspaceId: durableWorkspace.id,
      goalId: started.value.goalId,
      leaseToken: started.value.leaseToken,
      goalLease: proof,
      plan: {
        milestones: [{
          id: 'build', title: 'Build', goalStepId: 'build', dependsOn: [], provider: 'shell', role: 'blocking_job', cancelWithGoal: true,
          dispatch: {
            executable: process.execPath,
            arguments: ['-e', 'process.exit(0)'],
            cwd: workspaceRoot,
            timeoutSeconds: 30,
            maxOutputBytes: 16 * 1024,
            includeStdout: false,
            includeStderr: true,
          },
          verification: [{ id: 'exit', kind: 'command_exit', expectedExitCode: 0 }],
        }],
      },
      userConfirmed: true,
    });
    expect(created.isError).not.toBe(true);
    const runId = String(((created.structuredContent as { run?: { id?: unknown } } | undefined)?.run?.id));
    expect(runId).not.toBe('undefined');
    await first.close();

    const replacement = createStdioMcpRuntime(dataPath, durableWorkspace, true, { fullBypassAll: true });
    try {
      const registry = new ToolRegistry(replacement.services, replacement.actor, options);
      const restored = await registry.invoke('automation_status', { workspaceId: durableWorkspace.id, runId });
      expect(restored.isError).not.toBe(true);
      expect(restored.structuredContent).toMatchObject({ run: { id: runId, status: 'active', revision: 0 } });
      const foreignRead = await new ToolRegistry(replacement.services, { clientId: 'foreign-client', clientName: 'foreign' })
        .invoke('automation_status', { workspaceId: durableWorkspace.id, runId });
      expect(foreignRead).toMatchObject({ isError: true, structuredContent: { error: { code: 'PROCESS_NOT_FOUND' } } });

      let staleRevisionRejected = false;
      for (let boundary = 0; boundary < 10; boundary += 1) {
        const status = await registry.invoke('automation_status', { workspaceId: durableWorkspace.id, runId });
        if (status.isError === true) throw new Error(JSON.stringify(status.structuredContent));
        const snapshot = status.structuredContent as { run: { revision: number }; milestones: Array<{ status: string }> };
        if (snapshot.milestones.every((milestone) => milestone.status === 'completed')) break;
        const advanced = await registry.invoke('automation_run', {
          workspaceId: durableWorkspace.id,
          goalId: started.value.goalId,
          runId,
          leaseToken: started.value.leaseToken,
          expectedRevision: snapshot.run.revision,
          goalLease: proof,
          userConfirmed: true,
        });
        if (advanced.isError === true) throw new Error(JSON.stringify(advanced.structuredContent));
        if (!staleRevisionRejected) {
          const stale = await registry.invoke('automation_run', {
            workspaceId: durableWorkspace.id,
            goalId: started.value.goalId,
            runId,
            leaseToken: started.value.leaseToken,
            expectedRevision: snapshot.run.revision,
            goalLease: proof,
            userConfirmed: true,
          });
          expect(stale).toMatchObject({ isError: true, structuredContent: { error: { code: 'CONFLICT' } } });
          staleRevisionRejected = true;
        }
        await new Promise((resolve) => setTimeout(resolve, 25));
      }
      expect(staleRevisionRejected).toBe(true);

      const verified = await registry.invoke('automation_status', { workspaceId: durableWorkspace.id, runId });
      expect(verified.isError).not.toBe(true);
      expect(verified.structuredContent).toMatchObject({ milestones: [{ status: 'completed' }] });
      const revision = (verified.structuredContent as { run: { revision: number } }).run.revision;
      const finalized = await registry.invoke('automation_finalize', {
        workspaceId: durableWorkspace.id,
        goalId: started.value.goalId,
        runId,
        leaseToken: started.value.leaseToken,
        expectedRevision: revision,
        goalLease: proof,
        userConfirmed: true,
      });
      expect(finalized.isError).not.toBe(true);
      expect(finalized.structuredContent).toMatchObject({
        run: { run: { id: runId, status: 'completed' } }, goal: { status: 'completed' },
      });
    } finally {
      await replacement.close();
    }

    const inspected = new SqliteDatabase(path.join(dataPath, 'lnwjud.sqlite'));
    expect(inspected.connection.prepare('SELECT COUNT(*) AS count FROM goal_scheduled_continuations').get()).toEqual({ count: 0 });
    inspected.close();
  }, 30_000);

  it('observes persisted tool availability writes from another SQLite connection without restart or duplicate unrelated notifications', async () => {
    const dataPath = await mkdtemp(path.join(os.tmpdir(), 'lnwjud-stdio-tool-availability-'));
    temporaryRoots.push(dataPath);
    const runtime = createStdioMcpRuntime(dataPath, workspace);
    const externalDatabase = new SqliteDatabase(path.join(dataPath, 'lnwjud.sqlite'));
    const externalSettings = new SqliteSettingsRepository(externalDatabase);
    let notifications = 0;
    const unsubscribe = runtime.toolAvailabilityService.subscribe(() => { notifications += 1; });
    try {
      externalSettings.set(USER_SETTING_KEYS.toolAvailability, serializeToolAvailabilitySnapshot({
        version: 1,
        generation: 1,
        overrides: { scheduler: 'disabled' },
      }));
      await waitUntil(() => runtime.toolAvailabilityService.snapshot().overrides.scheduler === 'disabled');
      expect(notifications).toBe(1);

      externalSettings.set(USER_SETTING_KEYS.updateAutoCheck, 'false');
      await new Promise((resolve) => setTimeout(resolve, 350));
      expect(notifications).toBe(1);
    } finally {
      unsubscribe();
      externalDatabase.close();
      await runtime.close();
    }
  });

  it('reads current persisted Direct STDIO security settings without restarting the runtime', async () => {
    const dataPath = await mkdtemp(path.join(os.tmpdir(), 'lnwjud-stdio-security-policy-'));
    temporaryRoots.push(dataPath);
    const runtime = createStdioMcpRuntime(dataPath, workspace);
    const externalDatabase = new SqliteDatabase(path.join(dataPath, 'lnwjud.sqlite'));
    const externalSettings = new SqliteSettingsRepository(externalDatabase);
    try {
      externalSettings.set(STDIO_PERMISSION_PROFILE_SETTING_KEY, 'safe');
      externalSettings.set(USER_SETTING_KEYS.stdioFullBypassAll, 'true');
      externalSettings.set(STDIO_STRICT_ROOTS_SETTING_KEY, 'true');
      externalSettings.set(STDIO_ALLOWED_ROOTS_SETTING_KEY, 'E:\\one;E:\\two');
      externalSettings.set(UNRESTRICTED_SETTING_KEY, 'false');
      externalSettings.set(USER_SETTING_KEYS.customPermissionProfile, '{"read":"ASK"}');
      expect(runtime.persistedSecurityPolicyProvider()).toEqual({
        profile: 'safe',
        fullBypassAll: true,
        strictRoots: true,
        allowedRoots: ['E:\\one', 'E:\\two'],
        unrestricted: false,
        customPermissionRaw: '{"read":"ASK"}',
      });
    } finally {
      externalDatabase.close();
      await runtime.close();
    }
  });

  it('does not overwrite the Desktop permission profile when using full tunnel access', async () => {
    const dataPath = await mkdtemp(path.join(os.tmpdir(), 'lnwjud-stdio-profile-'));
    temporaryRoots.push(dataPath);
    const database = new SqliteDatabase(path.join(dataPath, 'lnwjud.sqlite'));
    new SqliteSettingsRepository(database).set('permission_profile', 'balanced');
    database.close();

    const runtime = createStdioMcpRuntime(dataPath, workspace);
    await runtime.close();

    const verificationDatabase = new SqliteDatabase(path.join(dataPath, 'lnwjud.sqlite'));
    const profile = new SqliteSettingsRepository(verificationDatabase).get('permission_profile');
    verificationDatabase.close();
    expect(profile).toBe('balanced');
  });

  it('owns and cleans the tunnel-profile activity snapshot for the direct STDIO runtime', async () => {
    const dataPath = await mkdtemp(path.join(os.tmpdir(), 'lnwjud-stdio-activity-'));
    const profileDirectory = await mkdtemp(path.join(os.tmpdir(), 'lnwjud-stdio-profile-'));
    temporaryRoots.push(dataPath, profileDirectory);
    process.env.TUNNEL_CLIENT_PROFILE_DIR = profileDirectory;

    const runtime = createStdioMcpRuntime(dataPath, workspace);
    await runtime.activityReady;
    const leaseDirectory = sharedActivityLeaseDirectoryPath(profileDirectory);
    const [leaseFile] = await readdir(leaseDirectory);
    expect(leaseFile).toBeDefined();
    const leasePath = path.join(leaseDirectory, leaseFile!);
    const initialized = JSON.parse(await readFile(leasePath, 'utf8')) as Record<string, unknown>;
    expect(initialized).toMatchObject({ version: 2, activeCount: 0, revision: 0, owner: { pid: process.pid } });

    const callId = await runtime.activityTracker.begin('read_file', { path: 'E:\\fixture.txt' });
    expect(JSON.parse(await readFile(leasePath, 'utf8'))).toMatchObject({ activeCount: 1, revision: 1 });
    await runtime.activityTracker.end(callId, 'SUCCESS', 1);
    expect(JSON.parse(await readFile(leasePath, 'utf8'))).toMatchObject({ activeCount: 0, revision: 2 });

    await runtime.close();
    expect((await readdir(leaseDirectory)).filter((name) => name.endsWith('.json'))).toEqual([]);
  });

  it('uses the selected stdio profile and hides broad workspaces when strict roots are enabled', async () => {
    const dataPath = await mkdtemp(path.join(os.tmpdir(), 'lnwjud-stdio-strict-data-'));
    const allowedRaw = await mkdtemp(path.join(os.tmpdir(), 'lnwjud-stdio-strict-allowed-'));
    const outsideRaw = await mkdtemp(path.join(os.tmpdir(), 'lnwjud-stdio-strict-outside-'));
    temporaryRoots.push(dataPath, allowedRaw, outsideRaw);
    const allowed = await realpath(allowedRaw);
    const outside = await realpath(outsideRaw);
    await writeFile(path.join(outside, 'outside.txt'), 'outside', 'utf8');
    const allowedWorkspace = { id: 'allowed-workspace', displayName: 'allowed', rootPath: allowed, realRootPath: allowed, createdAt: '2026-08-22T00:00:00.000Z' };
    const outsideWorkspace = { id: 'outside-workspace', displayName: 'outside', rootPath: outside, realRootPath: outside, createdAt: '2026-08-22T00:00:01.000Z' };
    const database = new SqliteDatabase(path.join(dataPath, 'lnwjud.sqlite'));
    const repo = new SqliteWorkspaceRepository(database);
    await repo.insert(allowedWorkspace);
    await repo.insert(outsideWorkspace);
    database.close();

    const runtime = createStdioMcpRuntime(dataPath, allowedWorkspace, true, { permissionProfile: 'safe', strictAllowedRoots: [allowed] });
    try {
      expect(runtime.profileProvider()).toEqual(permissionProfiles.safe);
      const listed = await runtime.services.workspaceInfo?.list?.(runtime.actor);
      expect(listed).toMatchObject({ ok: true, value: [expect.objectContaining({ id: 'allowed-workspace' })] });
      const readOutside = await runtime.services.file?.readFile(runtime.actor, undefined, { path: path.join(outside, 'outside.txt') });
      expect(readOutside).toMatchObject({ ok: false, error: { code: 'PATH_OUTSIDE_WORKSPACE' } });
      const shellOutside = await runtime.services.capabilities?.execute('shell', {
        operation: 'run', executable: process.execPath, arguments: ['-e', 'process.exit(0)'], cwd: outside, execution: 'foreground',
      });
      expect(shellOutside).toMatchObject({ ok: false, error: { code: 'PATH_OUTSIDE_WORKSPACE' } });
    } finally {
      await runtime.close();
    }
  });

  it('keeps a shell background task alive across STDIO runtime replacement', async () => {
    const dataPath = await mkdtemp(path.join(os.tmpdir(), 'lnwjud-stdio-durable-'));
    temporaryRoots.push(dataPath);
    const firstRuntime = createStdioMcpRuntime(dataPath, workspace, true);
    const capabilities = firstRuntime.services.capabilities;
    expect(capabilities).toBeDefined();
    if (capabilities === undefined) return;

    const started = await capabilities.execute('shell', {
      operation: 'run',
      executable: process.execPath,
      arguments: ['-e', "setTimeout(() => process.stdout.write('stdio-durable'), 350)"],
      cwd: dataPath,
      execution: 'background',
      timeout_seconds: 30,
      userConfirmed: true,
    });
    expect(started).toMatchObject({ ok: true, value: { task_id: expect.any(String), durable: true } });
    if (!started.ok) {
      await firstRuntime.close();
      return;
    }
    const taskId = String((started.value as Record<string, unknown>).task_id);
    await firstRuntime.close();

    const replacementRuntime = createStdioMcpRuntime(dataPath, workspace, true);
    const replacementCapabilities = replacementRuntime.services.capabilities;
    expect(replacementCapabilities).toBeDefined();
    if (replacementCapabilities === undefined) {
      await replacementRuntime.close();
      return;
    }
    const finished = await replacementCapabilities.execute('shell', { operation: 'wait', task_id: taskId, timeout_seconds: 5 });
    expect(finished).toMatchObject({
      ok: true,
      value: { task_id: taskId, state: 'completed', exit_code: 0, stdout: 'stdio-durable', durable: true },
    });
    await replacementRuntime.close();
  }, 15_000);

  it('reads durable shell task liveness after STDIO runtime replacement without treating another session as absence', async () => {
    const dataPath = await mkdtemp(path.join(os.tmpdir(), 'lnwjud-stdio-goal-liveness-data-'));
    const workspaceRoot = await mkdtemp(path.join(os.tmpdir(), 'lnwjud-stdio-goal-liveness-workspace-'));
    temporaryRoots.push(dataPath, workspaceRoot);
    const durableWorkspace = {
      id: 'goal-liveness-workspace',
      displayName: 'goal liveness',
      rootPath: workspaceRoot,
      realRootPath: workspaceRoot,
      createdAt: '2026-08-27T00:00:00.000Z',
    };
    const database = new SqliteDatabase(path.join(dataPath, 'lnwjud.sqlite'));
    await new SqliteWorkspaceRepository(database).insert(durableWorkspace);
    database.close();

    const ownerMetadata = {
      [CAPABILITY_TASK_OWNER_METADATA_KEY]: {
        clientId: 'cli-mcp-stdio',
        sessionId: 'predecessor-session',
        workspaceId: durableWorkspace.id,
      },
    };
    const firstRuntime = createStdioMcpRuntime(dataPath, durableWorkspace, true);
    const started = await firstRuntime.services.capabilities?.execute('shell', {
      operation: 'run',
      executable: process.execPath,
      arguments: ['-e', 'setTimeout(() => process.exit(0), 10000)'],
      cwd: workspaceRoot,
      workspaceId: durableWorkspace.id,
      execution: 'background',
      timeout_seconds: 30,
      userConfirmed: true,
      metadata: ownerMetadata,
    });
    expect(started).toMatchObject({ ok: true, value: { task_id: expect.any(String), state: 'running', durable: true } });
    if (started === undefined || !started.ok) {
      await firstRuntime.close();
      return;
    }
    const taskId = String((started.value as Record<string, unknown>).task_id);
    const runGoal = await firstRuntime.services.goals?.runGoal(firstRuntime.actor, {
      workspaceId: durableWorkspace.id,
      goalKey: 'runtime-task-state-reader',
      objective: 'Verify task liveness survives a transport replacement.',
      plan: { steps: [] },
      leaseSeconds: 600,
    });
    expect(runGoal).toMatchObject({ ok: true, value: { acquired: true, leaseToken: expect.any(String) } });
    if (runGoal === undefined || !runGoal.ok || runGoal.value.leaseToken === undefined) {
      await firstRuntime.close();
      return;
    }
    const checkpointed = await firstRuntime.services.goals?.checkpointGoal(firstRuntime.actor, {
      goalId: runGoal.value.goalId,
      leaseToken: runGoal.value.leaseToken,
      expectedRevision: runGoal.value.revision,
      currentPhase: 'worker-running',
      summary: 'A durable task is still running.',
      stepUpdates: [],
      nextAction: 'Wait for the task.',
      blockers: [],
      evidence: [],
      activeTaskIds: [taskId],
    });
    expect(checkpointed).toMatchObject({ ok: true, value: { activeTaskIds: [taskId] } });
    await firstRuntime.close();

    const replacementRuntime = createStdioMcpRuntime(dataPath, durableWorkspace, true);
    try {
      const liveness = await replacementRuntime.services.goalMutationFence?.observe(runGoal.value.goalId, [taskId]);
      expect(liveness).toMatchObject({
        trustworthy: true,
        activeTaskStates: [{ taskId, state: 'running' }],
      });
    } finally {
      await replacementRuntime.services.capabilities?.execute('shell', {
        operation: 'cancel',
        task_id: taskId,
        workspaceId: durableWorkspace.id,
        userConfirmed: true,
        metadata: ownerMetadata,
      });
      await replacementRuntime.close();
    }
  }, 15_000);
});
