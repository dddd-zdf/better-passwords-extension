import type { SessionChallenge } from "./session/session.ts";

/** The small native host that reads the code from the iCloud for Windows pairing window. */
export const WINDOWS_PAIRING_HOST = "io.github.fanckush.betterpasswords.windows_pairing";

export interface WindowsPairingReply {
  ok: boolean;
  error?: string;
  message?: string;
  code?: string;
}

export class WindowsPairingError extends Error {
  constructor(
    message: string,
    readonly code: string,
  ) {
    super(message);
    this.name = "WindowsPairingError";
  }
}

type SendNative = (host: string, message: object) => Promise<unknown>;
type ConnectNative = (host: string) => Browser.runtime.Port;
type Challenge = Promise<SessionChallenge>;

const HELLO_MS = 3_500;
const REQUEST_MS = 8_000;

function within<T>(promise: Promise<T>, ms: number, message: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new WindowsPairingError(message, "timeout")), ms);
    promise.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (error) => {
        clearTimeout(timer);
        reject(error);
      },
    );
  });
}

/**
 * Coordinates the Windows pairing reader. The one-shot hello is only a readiness probe. Unlocking
 * uses a separate persistent native port so arm, challenge and read-code belong to one host run.
 */
export class WindowsPairing {
  #attempt: Promise<void> | undefined;

  constructor(
    private readonly sendNative: SendNative = (host, message) => browser.runtime.sendNativeMessage(host, message),
    private readonly connectNative: ConnectNative = (host) => browser.runtime.connectNative(host),
  ) {}

  async state(): Promise<"ready" | "unavailable"> {
    try {
      const reply = (await within(
        this.sendNative(WINDOWS_PAIRING_HOST, { type: "hello" }),
        HELLO_MS,
        "The Windows pairing helper didn't answer.",
      )) as WindowsPairingReply | undefined;
      return reply?.ok === true ? "ready" : "unavailable";
    } catch {
      return "unavailable";
    }
  }

  /** Runs at most one host attempt at a time; duplicate popup clicks share its result. */
  unlock(
    requestChallenge: () => Challenge,
    verifyCode: (code: string, challenge: SessionChallenge) => Promise<void>,
  ): Promise<void> {
    this.#attempt ??= this.#run(requestChallenge, verifyCode).finally(() => {
      this.#attempt = undefined;
    });
    return this.#attempt;
  }

  async #run(
    requestChallenge: () => Challenge,
    verifyCode: (code: string, challenge: SessionChallenge) => Promise<void>,
  ): Promise<void> {
    let port: Browser.runtime.Port | undefined;
    try {
      try {
        port = this.connectNative(WINDOWS_PAIRING_HOST);
      } catch (error) {
        throw new WindowsPairingError(messageOf(error), "not-installed");
      }
      const arm = await this.#request(port, { type: "arm" });
      if (!arm.ok) throw this.#failure(arm);
      const challenge = await requestChallenge();
      const reply = await this.#request(port, { type: "read-code" });
      if (!reply.ok || typeof reply.code !== "string" || !/^\d{6}$/.test(reply.code)) {
        throw this.#failure(reply);
      }
      // The code is passed directly to the background session and is never returned to the popup.
      await verifyCode(reply.code, challenge);
    } finally {
      try {
        port?.disconnect();
      } catch {
        // Disconnecting an already-closed native host is harmless.
      }
    }
  }

  #failure(reply: WindowsPairingReply): WindowsPairingError {
    return new WindowsPairingError(
      reply.message ?? "The Windows pairing helper couldn't read the code.",
      reply.error ?? "stable-code",
    );
  }

  #request(port: Browser.runtime.Port, message: object): Promise<WindowsPairingReply> {
    return new Promise<WindowsPairingReply>((resolve, reject) => {
      let settled = false;
      const timer = setTimeout(
        () => finish(() => reject(new WindowsPairingError("The Windows pairing helper didn't answer.", "timeout"))),
        REQUEST_MS,
      );
      const finish = (action: () => void) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        port.onMessage.removeListener(onMessage);
        port.onDisconnect.removeListener(onDisconnect);
        action();
      };
      const onMessage = (value: unknown) => finish(() => resolve((value ?? {}) as WindowsPairingReply));
      const onDisconnect = () =>
        finish(() => reject(new WindowsPairingError("The Windows pairing helper disconnected.", "closed")));
      port.onMessage.addListener(onMessage);
      port.onDisconnect.addListener(onDisconnect);
      try {
        port.postMessage(message);
      } catch (error) {
        finish(() => reject(new WindowsPairingError(messageOf(error), "failed")));
      }
    });
  }
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
