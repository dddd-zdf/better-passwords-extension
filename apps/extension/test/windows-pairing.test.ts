import { describe, expect, it } from "vitest";
import { WINDOWS_PAIRING_HOST, WindowsPairing } from "../src/windows-pairing.ts";

type Listener = (value?: unknown) => void;

function portFor(reply: (message: { type: string }) => unknown) {
  const messages: { type: string }[] = [];
  const messageListeners = new Set<Listener>();
  const disconnectListeners = new Set<Listener>();
  let disconnected = false;
  const port = {
    name: WINDOWS_PAIRING_HOST,
    onMessage: {
      addListener: (listener: Listener) => messageListeners.add(listener),
      removeListener: (listener: Listener) => messageListeners.delete(listener),
    },
    onDisconnect: {
      addListener: (listener: Listener) => disconnectListeners.add(listener),
      removeListener: (listener: Listener) => disconnectListeners.delete(listener),
    },
    postMessage: (message: unknown) => {
      messages.push(message as { type: string });
      const value = reply(message as { type: string });
      if (value instanceof Error) throw value;
      for (const listener of messageListeners) listener(value);
    },
    disconnect: () => {
      disconnected = true;
      for (const listener of disconnectListeners) listener();
    },
  } as unknown as Browser.runtime.Port;
  return { port, messages, wasDisconnected: () => disconnected };
}

describe("WindowsPairing", () => {
  it("probes with one-shot hello and runs arm/read-code on one port", async () => {
    const oneShot: unknown[] = [];
    const persistent = portFor((message) =>
      message.type === "read-code" ? { ok: true, code: "000000" } : { ok: true },
    );
    const pairing = new WindowsPairing(
      async (host, message) => {
        oneShot.push({ host, message });
        return { ok: true };
      },
      () => persistent.port,
    );
    expect(await pairing.state()).toBe("ready");
    let requested = false;
    let verified = "";
    await pairing.unlock(
      async () => {
        requested = true;
        return { revision: 1 };
      },
      async (code) => {
        verified = code;
      },
    );
    expect(oneShot).toEqual([{ host: WINDOWS_PAIRING_HOST, message: { type: "hello" } }]);
    expect(persistent.messages).toEqual([{ type: "arm" }, { type: "read-code" }]);
    expect(requested).toBe(true);
    expect(verified).toBe("000000");
    expect(persistent.wasDisconnected()).toBe(true);
  });

  it("deduplicates concurrent attempts and closes the port on host failure", async () => {
    const persistent = portFor((message) =>
      message.type === "arm" ? { ok: false, error: "stable-code", message: "The code window is not ready." } : {},
    );
    const pairing = new WindowsPairing(
      async () => ({ ok: true }),
      () => persistent.port,
    );
    let requests = 0;
    const first = pairing.unlock(
      async () => {
        requests++;
        return { revision: 1 };
      },
      async () => {},
    );
    const second = pairing.unlock(
      async () => {
        requests++;
        return { revision: 2 };
      },
      async () => {},
    );
    await expect(first).rejects.toMatchObject({ code: "stable-code", message: "The code window is not ready." });
    await expect(second).rejects.toMatchObject({ code: "stable-code" });
    expect(requests).toBe(0);
    expect(persistent.wasDisconnected()).toBe(true);
  });
});
