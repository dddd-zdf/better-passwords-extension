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

type ConnectNative = (host: string) => Browser.runtime.Port;
type Challenge = Promise<SessionChallenge>;

const REQUEST_MS = 8_000;

/** Uses one native port so arm, challenge and read-code belong to the same host run. */
export class WindowsPairing {
  #attempt: Promise<void> | undefined;

  constructor(private readonly connectNative: ConnectNative = (host) => browser.runtime.connectNative(host)) {}

  /** Concurrent requests share one host attempt. */
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
    let port: Browser.runtime.Port;
    try {
      port = this.connectNative(WINDOWS_PAIRING_HOST);
    } catch (error) {
      throw new WindowsPairingError(messageOf(error), "not-installed");
    }

    const connection = new AbortController();
    port.onDisconnect.addListener(() => {
      // Chrome exposes the reason only during this event, including when the companion exits
      // normally after sending its final reply.
      const reason = browser.runtime.lastError?.message ?? "The Windows pairing helper disconnected.";
      connection.abort(new WindowsPairingError(reason, "closed"));
    });

    try {
      const arm = await this.#request(port, connection.signal, { type: "arm" });
      if (!arm.ok) throw this.#failure(arm);
      const challenge = await requestChallenge();
      const reply = await this.#request(port, connection.signal, { type: "read-code" });
      if (!reply.ok || typeof reply.code !== "string" || !/^\d{6}$/.test(reply.code)) {
        throw this.#failure(reply);
      }
      // The code is passed directly to the background session and is never returned to the popup.
      await verifyCode(reply.code, challenge);
    } finally {
      if (!connection.signal.aborted) port.disconnect();
    }
  }

  #failure(reply: WindowsPairingReply): WindowsPairingError {
    return new WindowsPairingError(
      reply.message ?? "The Windows pairing helper couldn't read the code.",
      reply.error ?? "stable-code",
    );
  }

  #request(port: Browser.runtime.Port, connection: AbortSignal, message: object): Promise<WindowsPairingReply> {
    return new Promise<WindowsPairingReply>((resolve, reject) => {
      if (connection.aborted) {
        reject(connection.reason);
        return;
      }
      const timer = setTimeout(
        () => finish(() => reject(new WindowsPairingError("The Windows pairing helper didn't answer.", "timeout"))),
        REQUEST_MS,
      );
      const finish = (action: () => void) => {
        clearTimeout(timer);
        port.onMessage.removeListener(onMessage);
        connection.removeEventListener("abort", onDisconnect);
        action();
      };
      const onMessage = (value: unknown) => finish(() => resolve((value ?? {}) as WindowsPairingReply));
      const onDisconnect = () => finish(() => reject(connection.reason));
      port.onMessage.addListener(onMessage);
      connection.addEventListener("abort", onDisconnect);
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
