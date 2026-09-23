import { Client, InMemoryTransport } from '@modelcontextprotocol/client';
import { describe, expect, it, vi } from 'vitest';
import type { FileActor } from '@lnwjud/application';
import type { ToolAvailabilitySnapshot } from '@lnwjud/shared';
import { createMcpServer } from './server.js';
import type { McpApplicationServices } from './tool-registry.js';

const actor: FileActor = {
  clientId: 'tool-availability-test-client',
  clientName: 'tool-availability-test',
  sessionId: 'tool-availability-test-session',
};

describe('MCP server live tool availability', () => {
  it('updates one connected client live and debounces tools/list_changed notifications', async () => {
    let snapshot: ToolAvailabilitySnapshot = { version: 1, generation: 0, overrides: {} };
    const listeners = new Set<(next: ToolAvailabilitySnapshot) => void>();
    let unsubscribeCount = 0;

    const server = createMcpServer({
      services: {} as McpApplicationServices,
      actor,
      toolAvailabilitySnapshotProvider: () => snapshot,
      toolAvailabilitySubscribe(listener): () => void {
        listeners.add(listener);
        return () => {
          if (listeners.delete(listener)) unsubscribeCount += 1;
        };
      },
    });

    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    const client = new Client({ name: 'tool-availability-test-client', version: '1.0.0' });
    let toolListChangedNotifications = 0;
    client.setNotificationHandler('notifications/tools/list_changed', () => {
      toolListChangedNotifications += 1;
    });

    try {
      await server.connect(serverTransport);
      await client.connect(clientTransport);

      const initial = await client.listTools();
      expect(initial.tools.map((tool) => tool.name)).toContain('read_file');
      expect(initial.tools.map((tool) => tool.name)).toContain('get_goal_plan');
      expect(initial.tools.map((tool) => tool.name)).not.toContain('codex_run');

      snapshot = {
        version: 1,
        generation: 1,
        overrides: { read_file: 'disabled', get_goal_plan: 'disabled' },
      };
      for (const listener of [...listeners]) listener(snapshot);

      snapshot = {
        version: 1,
        generation: 2,
        overrides: { read_file: 'enabled', get_goal_plan: 'disabled' },
      };
      for (const listener of [...listeners]) listener(snapshot);

      await vi.waitFor(() => {
        expect(toolListChangedNotifications).toBe(1);
      });
      await new Promise((resolve) => setTimeout(resolve, 50));
      expect(toolListChangedNotifications).toBe(1);

      const updated = await client.listTools();
      expect(updated.tools.map((tool) => tool.name)).toContain('read_file');
      expect(updated.tools.map((tool) => tool.name)).not.toContain('get_goal_plan');
      expect(updated.tools.map((tool) => tool.name)).not.toContain('codex_run');
    } finally {
      await client.close().catch(() => undefined);
      await server.close().catch(() => undefined);
    }

    expect(unsubscribeCount).toBe(1);
    expect(listeners.size).toBe(0);
  });

  it('releases tool availability when only the underlying protocol server closes', async () => {
    const listeners = new Set<(next: ToolAvailabilitySnapshot) => void>();
    let unsubscribeCount = 0;
    const server = createMcpServer({
      services: {} as McpApplicationServices,
      actor,
      toolAvailabilitySubscribe(listener): () => void {
        listeners.add(listener);
        return () => {
          if (listeners.delete(listener)) unsubscribeCount += 1;
        };
      },
    });
    const [serverTransport, clientTransport] = InMemoryTransport.createLinkedPair();
    const client = new Client({ name: 'protocol-close-client', version: '0.1.0' });

    try {
      await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
      expect(listeners.size).toBe(1);

      await server.server.close();

      await vi.waitFor(() => {
        expect(listeners.size).toBe(0);
      });
    } finally {
      await client.close().catch(() => undefined);
      await server.close().catch(() => undefined);
    }

    expect(unsubscribeCount).toBe(1);
  });
});
