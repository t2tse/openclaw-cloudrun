import { spawn } from "node:child_process";
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import { registerSandboxBackend } from "openclaw/plugin-sdk/sandbox";

const SANDBOX_BINARY_PATH = process.env.OPENCLAW_SANDBOX_BINARY_PATH || "/usr/local/gcp/bin/sandbox";
const ALLOW_EGRESS = process.env.SANDBOX_ALLOW_EGRESS === "true" || process.env.SANDBOX_ALLOW_EGRESS === "1";

function runCommandRaw(command, args, stdin = null) {
  return new Promise((resolve) => {
    const child = spawn(command, args, { env: { ...process.env } });
    let stdout = Buffer.alloc(0);
    let stderr = Buffer.alloc(0);
    child.stdout.on("data", (data) => { stdout = Buffer.concat([stdout, data]); });
    child.stderr.on("data", (data) => { stderr = Buffer.concat([stderr, data]); });
    child.on("error", (err) => {
      resolve({ code: -1, stdout, stderr: Buffer.from(err.message) });
    });
    child.on("close", (code) => {
      resolve({ code: code ?? 0, stdout, stderr });
    });
    if (stdin != null) {
      child.stdin.write(stdin);
    }
    child.stdin.end();
  });
}

async function ensureSandboxRunning(sandboxId, workspaceDir) {
  const check = await runCommandRaw(SANDBOX_BINARY_PATH, ["exec", sandboxId, "--", "/bin/true"]);
  if (check.code === 0) {
    return;
  }

  const runArgs = [
    "run",
    "--detach",
    "--write",
    ...(ALLOW_EGRESS ? ["--allow-egress"] : []),
    "--mount", `type=bind,source=${workspaceDir},destination=${workspaceDir}`,
    sandboxId
  ];

  const start = await runCommandRaw(SANDBOX_BINARY_PATH, runArgs);
  if (start.code !== 0) {
    throw new Error(`Failed to start Cloud Run sandbox ${sandboxId}: ${start.stderr.toString("utf8")}`);
  }
}

class CloudRunSandboxHandle {
  constructor(params) {
    this.id = "cloud-run-sandbox";
    this.runtimeId = params.sessionKey;
    this.runtimeLabel = `cloud-run-sandbox:${params.sessionKey}`;
    this.workdir = params.workspaceDir;
    this.workspaceDir = params.workspaceDir;
  }

  async buildExecSpec(params) {
    const { command, args, workdir, env, usePty } = params;
    const positional = ["sh", ...(args || [])];
    const execArgs = ["exec"];

    if (env) {
      for (const [key, val] of Object.entries(env)) {
        execArgs.push("-e", `${key}=${val}`);
      }
    }

    const activeWorkdir = workdir || this.workdir;
    if (activeWorkdir) {
      execArgs.push("--workdir", activeWorkdir);
    }

    execArgs.push(
      this.runtimeId,
      "--",
      "/bin/sh", "-c", command, ...positional
    );

    return {
      argv: [SANDBOX_BINARY_PATH, ...execArgs],
      env: { ...process.env },
      stdinMode: usePty ? "pipe-open" : "pipe-closed"
    };
  }

  async runShellCommand(params) {
    await ensureSandboxRunning(this.runtimeId, this.workspaceDir);

    const spec = await this.buildExecSpec({
      command: params.script,
      args: params.args,
      workdir: params.workdir,
      env: params.env,
      usePty: params.usePty,
    });

    return new Promise((resolve, reject) => {
      const child = spawn(spec.argv[0], spec.argv.slice(1), { env: spec.env });
      let stdout = Buffer.alloc(0);
      let stderr = Buffer.alloc(0);

      child.stdout.on("data", (data) => { stdout = Buffer.concat([stdout, data]); });
      child.stderr.on("data", (data) => { stderr = Buffer.concat([stderr, data]); });
      child.on("error", reject);
      child.on("close", (rawCode) => {
        const code = rawCode ?? 0;
        if (code !== 0 && !params.allowFailure) {
          const stderrStr = stderr.toString("utf8");
          const summary = stderrStr.trim().split("\n").slice(-3).join(" | ").slice(0, 400);
          reject(Object.assign(
            new Error(`Cloud Run sandbox shell exited with code ${code}: ${summary}`),
            { code, stdout, stderr },
          ));
          return;
        }
        resolve({ code, stdout, stderr });
      });

      if (params.stdin != null) {
        child.stdin.write(params.stdin);
      }
      child.stdin.end();
    });
  }
}

export const cloudRunSandboxManager = {
  async describeRuntime({ entry }) {
    const check = await runCommandRaw(SANDBOX_BINARY_PATH, ["exec", entry.containerName, "--", "/bin/true"]);
    return {
      running: check.code === 0,
      actualConfigLabel: "cloud-run-sandbox",
      configLabelMatch: true,
    };
  },
  async removeRuntime({ entry }) {
    await runCommandRaw(SANDBOX_BINARY_PATH, ["delete", entry.containerName, "--force"]);
  }
};

export default definePluginEntry({
  id: "cloud-run-sandbox-provider",
  name: "Cloud Run Sandbox",
  kind: "tool",
  register(api) {
    registerSandboxBackend("cloud-run-sandbox", {
      factory: async (params) => {
        const sanitizedSessionKey = params.sessionKey.replace(/[^a-zA-Z0-9-]/g, "-").toLowerCase();
        await ensureSandboxRunning(sanitizedSessionKey, params.workspaceDir);
        return new CloudRunSandboxHandle({ ...params, sessionKey: sanitizedSessionKey });
      },
      manager: cloudRunSandboxManager
    });
  }
});

