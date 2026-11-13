import { afterEach, describe, expect, it, vi } from "vitest";
import { WINDOWS_PAIRING_HOST, WindowsPairing } from "../src/windows-pairing.ts";

type Listener = (value?: unknown) => void;

function portFor(reply: (message: { type: string }) => unknown) {
  const messages: { type: string }[] = [];
  const messageListeners = new Set<Listener>();
  const disconnectListeners = new Set<Listener>();
  let disconnected = false;
  const disconnect = () => {
    disconnected = true;
  };
  const exitHost = () => {
    disconnect();
    for (const listener of disconnectListeners) listener();
  };
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
    disconnect,
  } as unknown as Browser.runtime.Port;
  return { port, messages, exitHost, wasDisconnected: () => disconnected };
}

afterEach(() => vi.unstubAllGlobals());

describe("WindowsPairing", () => {
  it("runs arm/read-code on one port", async () => {
    const persistent = portFor((message) =>
      message.type === "read-code" ? { ok: true, code: "000000" } : { ok: true },
    );
    const pairing = new WindowsPairing((host) => {
      expect(host).toBe(WINDOWS_PAIRING_HOST);
      return persistent.port;
    });
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
    expect(persistent.messages).toEqual([{ type: "arm" }, { type: "read-code" }]);
    expect(requested).toBe(true);
    expect(verified).toBe("000000");
    expect(persistent.wasDisconnected()).toBe(true);
  });

  it("deduplicates concurrent attempts and closes the port on host failure", async () => {
    const persistent = portFor((message) =>
      message.type === "arm" ? { ok: false, error: "stable-code", message: "The code window is not ready." } : {},
    );
    const pairing = new WindowsPairing(() => persistent.port);
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

  it("checks Chrome's disconnect reason when the host exits after its reply", async () => {
    const lastError = vi.fn(() => ({ message: "Native host has exited." }));
    vi.stubGlobal("browser", {
      runtime: {
        get lastError() {
          return lastError();
        },
      },
    });
    const persistent = portFor(({ type }) => (type === "read-code" ? { ok: true, code: "000000" } : { ok: true }));
    const pairing = new WindowsPairing(() => persistent.port);
    await pairing.unlock(
      async () => ({ revision: 1 }),
      async () => persistent.exitHost(),
    );
    expect(lastError).toHaveBeenCalledOnce();
  });

  it("rejects with the browser's reason if the host exits between messages", async () => {
    vi.stubGlobal("browser", { runtime: { lastError: { message: "Native host has exited." } } });
    const persistent = portFor(() => ({ ok: true }));
    const pairing = new WindowsPairing(() => persistent.port);
    await expect(
      pairing.unlock(async () => {
        persistent.exitHost();
        return { revision: 1 };
      }, vi.fn()),
    ).rejects.toMatchObject({ code: "closed", message: "Native host has exited." });
    expect(persistent.messages).toEqual([{ type: "arm" }]);
  });
});
