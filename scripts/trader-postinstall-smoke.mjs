import { Client } from '@modelcontextprotocol/client';
import { StdioClientTransport } from '@modelcontextprotocol/client/stdio';
import fs from 'node:fs';
import path from 'node:path';

function arg(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

function extractJson(result) {
  if (result && typeof result === 'object' && result.structuredContent && typeof result.structuredContent === 'object') {
    return result.structuredContent;
  }
  const text = result?.content?.find?.((item) => item?.type === 'text')?.text;
  if (typeof text === 'string' && text.trim()) {
    try {
      return JSON.parse(text);
    } catch {
      return { text };
    }
  }
  return result;
}

function requireTool(tools, name) {
  const tool = tools.find((entry) => entry.name === name);
  if (!tool) throw new Error(`Required MCP tool is missing: ${name}`);
  return tool;
}

function schemaHasProperty(tool, property) {
  return Boolean(tool?.inputSchema?.properties?.[property]);
}

const exe = arg('--exe');
const workspacePath = arg('--workspace');
if (!exe || !workspacePath) {
  console.error('Usage: node trader-postinstall-smoke.mjs --exe <lnwjud.exe> --workspace <repo-root>');
  process.exit(2);
}
if (!fs.existsSync(exe)) throw new Error(`Installed lnwjud executable not found: ${exe}`);

const transport = new StdioClientTransport({
  command: exe,
  args: ['--mcp-stdio'],
  stderr: 'pipe',
});
let diagnostics = '';
transport.stderr?.on('data', (chunk) => {
  diagnostics += chunk.toString('utf8');
});

const client = new Client(
  { name: 'trader-lnwjud-postinstall-smoke', version: '1.0.0' },
  { versionNegotiation: { mode: { pin: '2026-07-28' } } },
);

let goal = null;
try {
  await client.connect(transport);
  const listed = await client.listTools();
  const tools = listed.tools;

  const required = [
    'workspace_list',
    'workspace_register',
    'project_profile_set',
    'skills_list',
    'run_goal',
    'get_goal',
    'checkpoint_goal',
    'finish_goal',
    'context_pressure',
  ];
  for (const name of required) requireTool(tools, name);

  const workspaceRegister = requireTool(tools, 'workspace_register');
  const projectProfileSet = requireTool(tools, 'project_profile_set');
  const skillsList = requireTool(tools, 'skills_list');
  const checkpointGoal = requireTool(tools, 'checkpoint_goal');

  if (!Array.isArray(workspaceRegister.inputSchema?.required) || !workspaceRegister.inputSchema.required.includes('path')) {
    throw new Error('workspace_register does not advertise path as required');
  }
  if (!schemaHasProperty(projectProfileSet, 'dryRun') || !schemaHasProperty(projectProfileSet, 'dry_run')) {
    throw new Error('project_profile_set dryRun/dry_run contract is missing');
  }
  if (!schemaHasProperty(skillsList, 'workspaceId')) {
    throw new Error('skills_list workspaceId contract is missing');
  }
  const checkpointSchemaText = JSON.stringify(checkpointGoal.inputSchema);
  if (!checkpointSchemaText.includes('activeTaskIds') || !checkpointSchemaText.includes('trackedTasks')) {
    throw new Error('checkpoint_goal task identity variants are missing');
  }

  const workspaceListResult = extractJson(await client.callTool({ name: 'workspace_list', arguments: {} }));
  const workspaces = Array.isArray(workspaceListResult)
    ? workspaceListResult
    : Array.isArray(workspaceListResult?.workspaces)
      ? workspaceListResult.workspaces
      : [];
  const normalizedTarget = path.resolve(workspacePath).toLowerCase();
  const workspace = workspaces.find((entry) => {
    const candidate = entry?.realRootPath ?? entry?.rootPath ?? entry?.path;
    return typeof candidate === 'string' && path.resolve(candidate).toLowerCase() === normalizedTarget;
  });
  if (!workspace?.id) {
    throw new Error(`No registered workspace matches ${workspacePath}; post-install smoke will not create persistent workspace state automatically.`);
  }

  const goalKey = `trader-postinstall-smoke-${Date.now()}`;
  goal = extractJson(await client.callTool({
    name: 'run_goal',
    arguments: {
      workspaceId: workspace.id,
      goalKey,
      objective: 'Verify installed Trader-patched lnwjud Durable Goal lifecycle after promotion.',
      scheduledContinuation: 'off',
      ponytailMode: 'off',
      leaseSeconds: 120,
    },
  }));

  if (!goal?.goalId || !goal?.leaseToken || !Number.isInteger(goal?.revision)) {
    throw new Error(`run_goal returned incomplete lease state: ${JSON.stringify(goal)}`);
  }

  const readBack = extractJson(await client.callTool({
    name: 'get_goal',
    arguments: { goalId: goal.goalId },
  }));
  if (readBack?.status !== 'active') {
    throw new Error(`get_goal did not return active status: ${JSON.stringify(readBack)}`);
  }

  const finished = extractJson(await client.callTool({
    name: 'finish_goal',
    arguments: {
      goalId: goal.goalId,
      leaseToken: goal.leaseToken,
      expectedRevision: readBack.revision,
      status: 'completed',
      summary: 'Trader post-install Durable Goal smoke completed.',
      evidence: [{ kind: 'note', value: 'Post-install MCP stdio contract and Durable Goal lifecycle smoke passed.' }],
    },
  }));

  if (finished?.status !== 'completed') {
    throw new Error(`finish_goal did not reach completed status: ${JSON.stringify(finished)}`);
  }

  console.log('TRADER_POSTINSTALL_SMOKE=PASS');
  console.log(`WORKSPACE_ID=${workspace.id}`);
  console.log(`SMOKE_GOAL_ID=${goal.goalId}`);
  console.log(`TOOL_COUNT=${tools.length}`);
} catch (error) {
  console.error('TRADER_POSTINSTALL_SMOKE=FAILED');
  console.error(error instanceof Error ? error.stack ?? error.message : String(error));
  if (diagnostics.trim()) {
    console.error('STDIO_DIAGNOSTICS_BEGIN');
    console.error(diagnostics.trim());
    console.error('STDIO_DIAGNOSTICS_END');
  }
  process.exitCode = 1;
} finally {
  try {
    await client.close();
  } catch {}
}
