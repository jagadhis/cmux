// Phone access: a second listener for the same sidecar.
//
// The sidecar's own listener takes only loopback hosts and the per-launch
// token cmux passes in, so it works only inside cmux on this Mac. With
// `--remote` (or CMUX_AGENT_CHAT_REMOTE=1) the sidecar also listens on
// 127.0.0.1:7740 for `tailscale serve`, which hands it the requests your
// phone makes to https://<this-mac>.<tailnet>.ts.net over your tailnet.
//
// That listener has its own token, kept in ~/.config/cmux/agent-chat-remote.json
// (mode 0600) so a home-screen bookmark survives restarts. Every route but
// /healthz sits under /<token>/, as on the local listener. Delete the file and
// restart the sidecar to revoke every phone that has the old link.
//
// Run `bun remote.ts` to print the phone link (`--copy` puts it on the
// clipboard, which Universal Clipboard hands to the iPhone).

import { randomBytes } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

export const DEFAULT_REMOTE_PORT = 7740;

export interface RemoteConfig {
  port: number;
  tokenFile: string;
  /** Hosts besides loopback and *.ts.net that may reach the listener, such as a custom domain. */
  extraHosts: string[];
}

type Env = Record<string, string | undefined>;

function flagValue(argv: string[], name: string): string | undefined {
  const eq = argv.find((arg) => arg.startsWith(`${name}=`));
  if (eq) return eq.slice(name.length + 1);
  const i = argv.indexOf(name);
  return i >= 0 && argv[i + 1] && !argv[i + 1].startsWith("--") ? argv[i + 1] : undefined;
}

export function defaultTokenFile(env: Env = process.env): string {
  return env.CMUX_AGENT_CHAT_REMOTE_TOKEN_FILE || join(env.HOME || homedir(), ".config", "cmux", "agent-chat-remote.json");
}

/** The phone listener's settings, or null when phone access is off. */
export function remoteConfig(argv: string[] = Bun.argv, env: Env = process.env): RemoteConfig | null {
  const enabled = argv.includes("--remote") || env.CMUX_AGENT_CHAT_REMOTE === "1";
  if (!enabled) return null;
  const rawPort = flagValue(argv, "--remote-port") ?? env.CMUX_AGENT_CHAT_REMOTE_PORT;
  const port = rawPort === undefined ? DEFAULT_REMOTE_PORT : Number(rawPort);
  if (!Number.isInteger(port) || port <= 0 || port > 65535) throw new Error(`Not a port for phone access: ${rawPort}`);
  const extraHosts = (env.CMUX_AGENT_CHAT_REMOTE_HOSTS ?? "")
    .split(",")
    .map((host) => host.trim().toLowerCase())
    .filter(Boolean);
  return { port, tokenFile: defaultTokenFile(env), extraHosts };
}

function newToken(): string {
  // 256 bits, URL-safe and a single path segment.
  return randomBytes(32).toString("base64url");
}

function isToken(value: unknown): value is string {
  return typeof value === "string" && /^[A-Za-z0-9_-]{32,}$/.test(value);
}

/** The saved phone token, made on first use. The file stays readable by this user only. */
export function loadOrCreateRemoteToken(path: string): string {
  if (existsSync(path)) {
    let saved: unknown;
    try {
      saved = JSON.parse(readFileSync(path, "utf8"))?.token;
    } catch {
      saved = undefined;
    }
    if (isToken(saved)) {
      chmodSync(path, 0o600);
      return saved;
    }
  }
  const token = newToken();
  mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.${process.pid}.tmp`;
  writeFileSync(tmp, JSON.stringify({ token, createdAt: new Date().toISOString() }) + "\n", { mode: 0o600 });
  renameSync(tmp, path);
  return token;
}

function hostnameOf(host: string): string | null {
  try {
    return new URL(`http://${host}`).hostname.toLowerCase();
  } catch {
    return null;
  }
}

const LOOPBACK = new Set(["127.0.0.1", "localhost", "::1", "[::1]"]);

/**
 * Whether a Host header may reach the phone listener: loopback (for checks on
 * this Mac), a Tailscale MagicDNS name, or a host listed in
 * CMUX_AGENT_CHAT_REMOTE_HOSTS. Anything else is a page that rebound its own
 * name to this Mac, and is refused.
 */
export function remoteHostTrusted(hostHeader: string | null, extraHosts: string[] = []): boolean {
  const name = hostnameOf(hostHeader ?? "");
  if (!name) return false;
  return LOOPBACK.has(name) || name.endsWith(".ts.net") || extraHosts.includes(name);
}

/**
 * Whether a request's Origin may use the phone listener: none (curl, scripts),
 * or the page's own address, so another site open on the phone can't drive it.
 */
export function remoteOriginTrusted(origin: string | null, hostHeader: string | null, extraHosts: string[] = []): boolean {
  if (origin === null) return true;
  if (!remoteHostTrusted(hostHeader, extraHosts)) return false;
  try {
    const url = new URL(origin);
    if (url.host !== (hostHeader ?? "").toLowerCase()) return false;
    return url.protocol === "https:" || (url.protocol === "http:" && LOOPBACK.has(url.hostname));
  } catch {
    return false;
  }
}

// MARK: - Printing the phone link

function tailscaleBinary(): string | null {
  for (const candidate of [Bun.which("tailscale"), "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]) {
    if (candidate && existsSync(candidate)) return candidate;
  }
  return null;
}

/** This Mac's MagicDNS name, such as `my-mac.tail1234.ts.net`, when Tailscale is running. */
function tailscaleName(binary: string): string | null {
  const result = Bun.spawnSync([binary, "status", "--json"], { stderr: "ignore" });
  if (result.exitCode !== 0) return null;
  try {
    const name = JSON.parse(result.stdout.toString())?.Self?.DNSName;
    return typeof name === "string" && name ? name.replace(/\.$/, "") : null;
  } catch {
    return null;
  }
}

/** The phone link for a host and token. */
export function phoneUrl(host: string, token: string): string {
  return `https://${host}/${token}/home`;
}

if (import.meta.main) {
  const config = remoteConfig(["--remote", ...Bun.argv.slice(2)]);
  if (!config) throw new Error("unreachable");
  const token = loadOrCreateRemoteToken(config.tokenFile);
  const binary = tailscaleBinary();
  const host = binary ? tailscaleName(binary) : null;
  if (!binary) {
    console.log("Tailscale isn't installed. Install it on this Mac and on your iPhone, sign both in to the same account, then run this again.");
    process.exit(1);
  }
  if (!host) {
    console.log("Tailscale is installed but not connected. Open it, sign in, then run this again.");
    process.exit(1);
  }
  const url = phoneUrl(host, token);
  console.log(`Phone link (keep it private, it's the key):\n\n  ${url}\n`);
  console.log(`If you haven't yet, publish the listener to your tailnet once:\n\n  ${binary} serve --bg ${config.port}\n`);
  console.log("Use `serve`, never `funnel`: funnel puts it on the public internet.");
  if (Bun.argv.includes("--copy")) {
    const copy = Bun.spawnSync(["pbcopy"], { stdin: new TextEncoder().encode(url) });
    console.log(copy.exitCode === 0 ? "\nCopied. Paste it in Safari on your iPhone." : "\nCouldn't copy it; copy the link above.");
  }
}
