import { defineTool, type McpToolContext, type McpToolDefinition } from './tool-types.js';
import { UPGRADE_TOOL_CATALOG } from '../upgrade-catalog.js';
import { UpgradeRuntimeService } from '../upgrade-runtime.js';
import type { IncrementalVerifier } from '../incremental-verifier.js';
import type { ActivityTracker } from '../activity-tracker.js';
import {
  upgradeToolAnnotations,
  upgradeToolExecution,
  upgradeToolInputSchema,
  upgradeToolOutputSchema,
} from '../upgrade-tool-contracts.js';

export const SPECIALIZED_RUNTIME_TOOL_NAMES = new Set([
  'agent_swarm_run',
  'automation_create',
  'automation_status',
  'automation_events',
  'automation_run',
  'automation_control',
  'automation_finalize',
]);

/**
 * Upgrade tools are registered from one authoritative contract boundary.
 * Each tool receives a strict, tool-specific input schema so hallucinated or
 * misspelled arguments fail validation instead of being silently ignored.
 * The shared output envelope remains intentionally extensible because runtime
 * evidence is tool-specific and can grow compatibly without widening inputs.
 */
export function upgradeTools(context: McpToolContext, incrementalVerifier: IncrementalVerifier, activityTracker?: ActivityTracker): McpToolDefinition[] {
  const runtime = new UpgradeRuntimeService(context.services, context.actor, context.contextEconomy, context.isToolExposed, incrementalVerifier, activityTracker, context.getToolDefinition);
  return UPGRADE_TOOL_CATALOG.filter((entry) => !SPECIALIZED_RUNTIME_TOOL_NAMES.has(entry.name)).map((entry) => defineTool({
    name: entry.name,
    description: entry.description,
    permission: entry.permission,
    annotations: upgradeToolAnnotations(entry),
    inputSchema: upgradeToolInputSchema(entry),
    outputSchema: upgradeToolOutputSchema,
    execution: upgradeToolExecution(entry),
    handler: async (input, signal, authorization) => runtime.execute(entry.name, input, signal, authorization),
  }));
}
