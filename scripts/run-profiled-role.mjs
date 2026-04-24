#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const rootDir = path.resolve(__dirname, "..");

// Action name (stable contract for callers) → skill folder name (now `_<action>` after the
// internal-skill rename). Action names stay short; the underscore is an implementation detail.
const actionSkills = {
  "review-plan-history": "_review-plan-history",
  "review-plan-rules": "_review-plan-rules",
  "review-plan-security": "_review-plan-security",
  "review-plan-cost": "_review-plan-cost",
  "review-correctness": "_review-correctness",
  "review-against-rules": "_review-against-rules",
  "red-team-review": "_red-team-review",
  "scope-check": "_scope-check",
  "estimate-effort": "_estimate-effort"
};

function parseArgs(argv) {
  const args = {};
  for (let i = 2; i < argv.length; i += 1) {
    const value = argv[i];
    if (value === "--help" || value === "-h") args.help = true;
    else if (value === "--dry-run") args.dryRun = true;
    else if (value === "--profile") args.profile = argv[++i];
    else if (value === "--role") args.role = argv[++i];
    else if (value === "--action") args.action = argv[++i];
    else if (value === "--workdir") args.workdir = argv[++i];
    else if (value === "--context-dir") args.contextDir = argv[++i];
    else if (value === "--plan-path") args.planPath = argv[++i];
    else if (value === "--ticket-code") args.ticketCode = argv[++i];
    else if (value === "--question") args.question = argv[++i];
    else if (value === "--output") args.output = argv[++i];
    else throw new Error(`Unknown argument: ${value}`);
  }
  return args;
}

function requireArg(args, name) {
  if (!args[name]) throw new Error(`Missing required argument --${name.replace(/[A-Z]/g, (m) => `-${m.toLowerCase()}`)}`);
}

function resolveProfile(args) {
  const resolverArgs = [path.join(rootDir, "scripts", "resolve-profile.mjs")];
  if (args.profile) resolverArgs.push("--profile", args.profile);
  if (args.workdir) resolverArgs.push("--target-repo", args.workdir);

  const result = spawnSync(process.execPath, resolverArgs, {
    cwd: rootDir,
    encoding: "utf8"
  });

  if (result.status !== 0) {
    throw new Error(result.stderr.trim() || "resolve-profile failed");
  }

  return JSON.parse(result.stdout);
}

function readSkill(action) {
  const skillName = actionSkills[action];
  if (!skillName) return null;
  const skillPath = path.join(rootDir, "skills", skillName, "SKILL.md");
  if (!fs.existsSync(skillPath)) throw new Error(`Missing skill file for action ${action}: ${skillPath}`);
  return {
    skillName,
    skillPath,
    body: fs.readFileSync(skillPath, "utf8")
  };
}

function fallbackActionPrompt(args) {
  if (args.action === "ask") {
    return args.question || "No question was provided. Return an envelope explaining that ask requires a question.";
  }

  if (args.action === "review-plan") {
    return "Review the implementation plan at planPath using all files under contextDir. Look for missing files, regressions, simpler approaches, and tests. Return the standard Counselor envelope.";
  }

  if (args.action === "review-pr") {
    return "Read all files under contextDir, then run git diff in workdir and review the uncommitted changes for correctness, edge cases, regressions, and test gaps. Return the standard Counselor envelope.";
  }

  if (args.action === "red-team") {
    return "Read all files under contextDir, then run git diff in workdir and review the uncommitted changes adversarially for injection, authz, exposure, race, supply-chain, and DoS risks. Return the standard Counselor envelope.";
  }

  return `No action contract was found for ${args.action}. Return an envelope explaining that this external role action is unsupported.`;
}

function buildPrompt(args, roleConfig) {
  const skill = readSkill(args.action);
  const inputs = {
    workdir: args.workdir,
    contextDir: args.contextDir,
    planPath: args.planPath,
    ticketCode: args.ticketCode,
    question: args.question
  };

  const body = [
    `You are executing a thk role outside Claude Code.`,
    ``,
    `Role: ${args.role}`,
    `Action: ${args.action}`,
    `Runner: ${roleConfig.runner}`,
    roleConfig.model ? `Requested model: ${roleConfig.model}` : null,
    ``,
    `Inputs:`,
    JSON.stringify(inputs, null, 2),
    ``,
    `Shared contract:`,
    `- Read the session context from contextDir before reaching a verdict.`,
    `- Write any review artifact requested by the action contract into the path named by that contract.`,
    `- Return a concise JSON-like envelope with approved, issues or artifacts, reviewPath when relevant, and notes.`,
    `- If a tool named in the contract is unavailable in this runner, continue with the local files and say exactly what was skipped.`,
    ``,
    skill ? `Action contract from ${path.relative(rootDir, skill.skillPath)}:` : `Action prompt:`,
    skill ? skill.body : fallbackActionPrompt(args)
  ].filter((line) => line !== null);

  return `${body.join("\n")}\n`;
}

function expandArgs(templateArgs, prompt, roleConfig) {
  return templateArgs.map((arg) => arg
    .replaceAll("{{prompt}}", prompt)
    .replaceAll("{{model}}", roleConfig.model || "")
    .replaceAll("{{reasoning_effort}}", roleConfig.reasoning_effort || ""));
}

function commandForRunner(roleConfig, prompt) {
  if (roleConfig.runner === "codex-cli") {
    const args = [
      "exec",
      "--full-auto",
      "--disable",
      "enable_request_compression"
    ];

    if (roleConfig.model) args.push("-c", `model="${roleConfig.model}"`);
    if (roleConfig.reasoning_effort) args.push("-c", `model_reasoning_effort="${roleConfig.reasoning_effort}"`);
    args.push(prompt);
    return {
      command: "codex",
      args
    };
  }

  if (roleConfig.runner === "gemini-cli") {
    return {
      command: roleConfig.command || "gemini",
      args: expandArgs(roleConfig.args || ["-p", "{{prompt}}"], prompt, roleConfig)
    };
  }

  if (roleConfig.command) {
    return {
      command: roleConfig.command,
      args: expandArgs(roleConfig.args || ["{{prompt}}"], prompt, roleConfig)
    };
  }

  return null;
}

function writeOutput(outputPath, text) {
  if (!outputPath) return;
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, text);
}

function printHelp() {
  process.stdout.write(`Run one thk role through the selected profile.

Usage:
  node scripts/run-profiled-role.mjs --role grand_maester --action review-plan-history \\
    --workdir /repo/worktree --context-dir /session/context \\
    --plan-path /session/context/plan.md --ticket-code ENG-123

Supported external runners:
  codex-cli
  gemini-cli or any role with { "command": "...", "args": ["...", "{{prompt}}"] }

Claude Code roles should still be dispatched through the Claude Agent tool.
`);
}

function main() {
  const args = parseArgs(process.argv);
  if (args.help) {
    printHelp();
    return;
  }

  requireArg(args, "role");
  requireArg(args, "action");
  requireArg(args, "contextDir");

  const resolved = resolveProfile(args);
  const roleConfig = resolved.profile.roles[args.role];
  if (!roleConfig) throw new Error(`Profile ${resolved.selected_profile} has no role ${args.role}`);

  const prompt = buildPrompt(args, roleConfig);

  if (roleConfig.runner === "manual") {
    const promptPath = args.output || path.join(args.contextDir, "profiled-prompts", `${args.role}-${args.action}.md`);
    if (!args.dryRun) writeOutput(promptPath, prompt);
    process.stdout.write(`${JSON.stringify({
      approved: false,
      manual: true,
      dryRun: Boolean(args.dryRun),
      promptPath,
      notes: "manual runner selected; prompt was emitted instead of executed"
    }, null, 2)}\n`);
    return;
  }

  if (roleConfig.runner === "claude-code") {
    throw new Error("claude-code roles must be dispatched through the Claude Agent tool, not run-profiled-role.mjs");
  }

  const command = commandForRunner(roleConfig, prompt);
  if (!command) {
    throw new Error(`No command adapter configured for runner ${roleConfig.runner}`);
  }

  if (args.dryRun) {
    writeOutput(args.output, prompt);
    process.stdout.write(`${JSON.stringify({
      dryRun: true,
      selected_profile: resolved.selected_profile,
      role: args.role,
      action: args.action,
      command: command.command,
      args: command.args.map((arg) => arg === prompt ? "{{prompt}}" : arg),
      promptPath: args.output || null,
      warnings: resolved.warnings
    }, null, 2)}\n`);
    return;
  }

  const result = spawnSync(command.command, command.args, {
    cwd: args.workdir || process.cwd(),
    encoding: "utf8",
    maxBuffer: 1024 * 1024 * 50
  });

  const rawOutput = [result.stdout, result.stderr].filter(Boolean).join("\n");
  writeOutput(args.output, rawOutput);

  process.stdout.write(`${JSON.stringify({
    approved: result.status === 0,
    runner: roleConfig.runner,
    exitCode: result.status,
    rawOutputPath: args.output || null,
    rawOutput: args.output ? undefined : rawOutput,
    notes: result.status === 0 ? "external runner completed" : "external runner failed"
  }, null, 2)}\n`);
}

try {
  main();
} catch (error) {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = 1;
}
