#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const rootDir = path.resolve(__dirname, "..");
const builtInPath = path.join(rootDir, "config", "profiles.json");
const roleAgents = {
  master_of_whisperers: "master-of-whisperers",
  grand_maester: "grand-maester",
  master_of_laws: "master-of-laws",
  lord_commander: "lord-commander",
  master_of_coin: "master-of-coin",
  master_of_ships: "master-of-ships",
  counselor: "counselor"
};

function parseArgs(argv) {
  const args = {
    json: true,
    configPaths: []
  };

  for (let i = 2; i < argv.length; i += 1) {
    const value = argv[i];
    if (value === "--help" || value === "-h") args.help = true;
    else if (value === "--list") args.list = true;
    else if (value === "--detect") args.detectOnly = true;
    else if (value === "--init") args.init = true;
    else if (value === "--dry-run") args.dryRun = true;
    else if (value === "--profile") args.profile = argv[++i];
    else if (value === "--target-repo") args.targetRepo = argv[++i];
    else if (value === "--config") args.configPaths.push(argv[++i]);
    else throw new Error(`Unknown argument: ${value}`);
  }

  return args;
}

function readJson(filePath, required = false) {
  if (!filePath || !fs.existsSync(filePath)) {
    if (required) throw new Error(`Missing JSON file: ${filePath}`);
    return null;
  }

  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch (error) {
    throw new Error(`Failed to parse ${filePath}: ${error.message}`);
  }
}

function expandHome(filePath) {
  if (!filePath) return filePath;
  if (filePath === "~") return os.homedir();
  if (filePath.startsWith("~/")) return path.join(os.homedir(), filePath.slice(2));
  return filePath;
}

function absoluteMaybe(filePath) {
  if (!filePath) return filePath;
  const expanded = expandHome(filePath);
  return path.isAbsolute(expanded) ? expanded : path.resolve(process.cwd(), expanded);
}

function mergeConfigs(configs) {
  const merged = {
    version: 1,
    default_profile: undefined,
    roles: [],
    profiles: {},
    sources: {},
    mcps: {}
  };

  for (const config of configs) {
    if (!config) continue;
    if (config.version) merged.version = config.version;
    if (Array.isArray(config.roles)) merged.roles = config.roles;
    if (config.default_profile) merged.default_profile = config.default_profile;
    if (config.profiles && typeof config.profiles === "object") {
      merged.profiles = {
        ...merged.profiles,
        ...config.profiles
      };
    }
    if (config.sources && typeof config.sources === "object") {
      merged.sources = { ...merged.sources, ...config.sources };
    }
    if (config.mcps && typeof config.mcps === "object") {
      merged.mcps = { ...merged.mcps, ...config.mcps };
    }
  }

  return merged;
}

function commandPath(command) {
  try {
    return execFileSync("command", ["-v", command], {
      encoding: "utf8",
      shell: true,
      stdio: ["ignore", "pipe", "ignore"]
    }).trim() || null;
  } catch {
    return null;
  }
}

function pathExists(filePath) {
  return fs.existsSync(expandHome(filePath));
}

function detectMachine() {
  const commands = {
    claude: commandPath("claude"),
    codex: commandPath("codex"),
    gemini: commandPath("gemini"),
    cursor: commandPath("cursor")
  };

  const signals = {
    claudeConfigDir: pathExists("~/.claude"),
    codexConfigDir: pathExists("~/.codex"),
    geminiConfigDir: pathExists("~/.gemini"),
    cursorConfigDir: pathExists("~/.cursor"),
    anthropicApiKey: Boolean(process.env.ANTHROPIC_API_KEY || process.env.CLAUDE_API_KEY),
    openaiApiKey: Boolean(process.env.OPENAI_API_KEY),
    geminiApiKey: Boolean(process.env.GEMINI_API_KEY || process.env.GOOGLE_API_KEY),
    claudePluginRoot: Boolean(process.env.CLAUDE_PLUGIN_ROOT)
  };

  return {
    commands,
    signals,
    runners: {
      "claude-code": Boolean(commands.claude || signals.claudeConfigDir || signals.claudePluginRoot),
      "codex-cli": Boolean(commands.codex),
      "gemini-cli": Boolean(commands.gemini),
      cursor: Boolean(commands.cursor),
      "anthropic-api": signals.anthropicApiKey,
      "openai-api": signals.openaiApiKey,
      "google-api": signals.geminiApiKey,
      manual: true
    }
  };
}

function defaultConfigPaths(args) {
  // thk is per-project. The only config sources are:
  //   1. $THK_CONFIG — explicit override (per-shell / CI)
  //   2. <targetRepo>/.claude/.thk/config.json — committed alongside the project
  // No home-dir state. A teammate's machine resolves the same config from the
  // same files because they live in the repo.
  const paths = [];
  if (process.env.THK_CONFIG) paths.push(process.env.THK_CONFIG);
  if (args.targetRepo) paths.push(path.join(args.targetRepo, ".claude", ".thk", "config.json"));
  return paths.map(absoluteMaybe);
}

function loadConfig(args) {
  const builtIn = readJson(builtInPath, true);
  const explicitPaths = args.configPaths.map(absoluteMaybe);
  const configPaths = explicitPaths.length > 0 ? explicitPaths : defaultConfigPaths(args);
  const userConfigs = configPaths.map((configPath) => readJson(configPath)).filter(Boolean);
  return {
    config: mergeConfigs([builtIn, ...userConfigs]),
    paths: {
      builtIn: builtInPath,
      loaded: configPaths.filter((configPath) => fs.existsSync(configPath)),
      searched: configPaths
    }
  };
}

function inferRecommendedProfile(detection, profiles) {
  const has = (name) => Object.prototype.hasOwnProperty.call(profiles, name);
  const { runners } = detection;

  if (runners["claude-code"] && runners["codex-cli"] && has("claude_codex")) return "claude_codex";
  if (runners["codex-cli"] && (runners["claude-code"] || runners["anthropic-api"]) && has("codex_with_opus_counselor")) {
    return "codex_with_opus_counselor";
  }
  if (runners["codex-cli"] && has("codex_only")) return "codex_only";
  if (runners["gemini-cli"] && has("gemini_only")) return "gemini_only";
  if (runners["claude-code"] && has("claude_only")) return "claude_only";
  return has("portable_sequential") ? "portable_sequential" : Object.keys(profiles)[0];
}

function normalizeProfile(name, profile, roleList) {
  const roles = {};
  for (const role of roleList) {
    const roleConfig = profile.roles?.[role] || {};
    roles[role] = {
      ...roleConfig
    };

    if (role !== "hand" && roles[role].runner === "claude-code" && !roles[role].agent) {
      roles[role].agent = roleAgents[role] || role.replaceAll("_", "-");
    }
  }

  return {
    name,
    description: profile.description || "",
    parallel: profile.parallel !== false,
    roles
  };
}

function roleWarnings(profile, detection) {
  const warnings = [];

  for (const [role, config] of Object.entries(profile.roles)) {
    const runner = config.runner || "manual";
    if (!detection.runners[runner]) {
      warnings.push(`${role} uses ${runner}, but that runner was not detected on this machine`);
    }

    if (config.adapter?.runner && !detection.runners[config.adapter.runner]) {
      warnings.push(`${role} adapter uses ${config.adapter.runner}, but that runner was not detected on this machine`);
    }

    if (runner === "cursor") {
      warnings.push(`${role} uses cursor; Cursor does not currently expose a stable thk runner adapter`);
    }
  }

  if (!profile.parallel) {
    warnings.push("profile is sequential; the Hand should not assume parallel role dispatch");
  }

  return warnings;
}

function selectedProfileName(args, config, detection) {
  if (args.profile) return args.profile;
  if (process.env.THK_PROFILE) return process.env.THK_PROFILE;
  if (config.default_profile) return config.default_profile;
  return inferRecommendedProfile(detection, config.profiles);
}

function writeInitConfig(args, config, detection) {
  // Default to the repo-local path. --config <path> overrides; --target-repo is
  // required for the implicit default. thk is per-project — there's no
  // home-dir fallback by design.
  const repoLocalDefault = args.targetRepo
    ? path.join(args.targetRepo, ".claude", ".thk", "config.json")
    : null;
  const explicitPath = args.configPaths[0];
  if (!explicitPath && !repoLocalDefault) {
    throw new Error("--init requires either --config <path> or --target-repo <path> (thk config is per-project; no home-dir default).");
  }
  const outputPath = absoluteMaybe(explicitPath || repoLocalDefault);
  const defaultProfile = selectedProfileName(args, config, detection) || inferRecommendedProfile(detection, config.profiles);
  const existed = fs.existsSync(outputPath);
  const body = {
    version: 1,
    default_profile: defaultProfile,
    profiles: {}
  };

  if (!args.dryRun) {
    fs.mkdirSync(path.dirname(outputPath), { recursive: true });
    if (!existed) {
      fs.writeFileSync(outputPath, `${JSON.stringify(body, null, 2)}\n`);
    }
  }

  return {
    path: outputPath,
    created: !args.dryRun && !existed,
    existed,
    dryRun: Boolean(args.dryRun),
    config: body
  };
}

function printHelp() {
  process.stdout.write(`thk profile resolver

Usage:
  node scripts/resolve-profile.mjs [--profile NAME] [--target-repo PATH]
  node scripts/resolve-profile.mjs --init [--profile NAME] [--config PATH]
  node scripts/resolve-profile.mjs --list
  node scripts/resolve-profile.mjs --detect

Config resolution (per-project — no home-dir state):
  1. config/profiles.json in the plugin (built-in defaults)
  2. $THK_CONFIG, if set (explicit override)
  3. <targetRepo>/.claude/.thk/config.json, when --target-repo is provided

Profile selection:
  --profile wins, then $THK_PROFILE, then default_profile.
`);
}

function main() {
  const args = parseArgs(process.argv);
  if (args.help) {
    printHelp();
    return;
  }

  const detection = detectMachine();
  const { config, paths } = loadConfig(args);

  if (args.detectOnly) {
    process.stdout.write(`${JSON.stringify(detection, null, 2)}\n`);
    return;
  }

  if (args.list) {
    process.stdout.write(`${JSON.stringify({
      default_profile: config.default_profile,
      recommended_profile: inferRecommendedProfile(detection, config.profiles),
      profiles: Object.fromEntries(
        Object.entries(config.profiles).map(([name, profile]) => [name, profile.description || ""])
      )
    }, null, 2)}\n`);
    return;
  }

  if (args.init) {
    process.stdout.write(`${JSON.stringify(writeInitConfig(args, config, detection), null, 2)}\n`);
    return;
  }

  const profileName = selectedProfileName(args, config, detection);
  const rawProfile = config.profiles[profileName];
  if (!rawProfile) {
    throw new Error(`Unknown profile "${profileName}". Run --list to see available profiles.`);
  }

  const profile = normalizeProfile(profileName, rawProfile, config.roles);
  const result = {
    selected_profile: profileName,
    recommended_profile: inferRecommendedProfile(detection, config.profiles),
    config_paths: paths,
    profile,
    sources: config.sources || {},
    mcps: config.mcps || {},
    detected: detection,
    warnings: roleWarnings(profile, detection)
  };

  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
}

try {
  main();
} catch (error) {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = 1;
}
