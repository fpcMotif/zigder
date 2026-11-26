import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { basename, join, resolve } from "node:path";

interface CliArgs {
  url: string;
  dir: string;
  project: string;
  token: string;
}

interface ModuleDef {
  id: string;
  name: string;
  description: string;
  paths: string[];
  aliases: string[];
}

interface SyncArtifact {
  type: string;
  slug: string;
  title: string;
  content: string;
  modules: string[];
  meta: Record<string, unknown>;
  render_png_b64: string | null;
  note: string;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function parseArgs(argv: string[]): CliArgs {
  let url = process.env.RYUGI_HUB_URL ?? "";
  let dir = "/Users/martinfan/devv/zigder";
  let project = "";
  let token = process.env.RYUGI_HUB_TOKEN ?? "";

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--") {
      continue;
    }
    if (arg === "--url" && i + 1 < argv.length) {
      url = argv[i + 1];
      i += 1;
    } else if (arg === "--dir" && i + 1 < argv.length) {
      dir = argv[i + 1];
      i += 1;
    } else if (arg === "--project" && i + 1 < argv.length) {
      project = argv[i + 1];
      i += 1;
    } else if (arg === "--token" && i + 1 < argv.length) {
      token = argv[i + 1];
      i += 1;
    }
  }

  const resolvedDir = resolve(dir);
  return {
    url: url.replace(/\/+$/, ""),
    dir: resolvedDir,
    project: (project || basename(resolvedDir)).toLowerCase().replace(/[^a-z0-9._-]+/g, "-"),
    token
  };
}

function extractXmlTitle(xml: string, fallback: string): string {
  const match = xml.match(/<h1[^>]*>([\s\S]*?)<\/h1>/i);
  if (!match) {
    return fallback;
  }
  return (
    match[1]
      .replace(/<[^>]+>/g, "")
      .replace(/&amp;/g, "&")
      .replace(/&lt;/g, "<")
      .replace(/&gt;/g, ">")
      .replace(/&quot;/g, '"')
      .trim() || fallback
  );
}

function extractWhiteboardTitle(jsonText: string, fallback: string): string {
  try {
    const parsed: unknown = JSON.parse(jsonText);
    if (isRecord(parsed) && isRecord(parsed.appState) && typeof parsed.appState.name === "string") {
      return parsed.appState.name.trim() || fallback;
    }
  } catch {
  }
  return fallback;
}

function readModules(ryugiDir: string): ModuleDef[] {
  const modPath = join(ryugiDir, "modules.json");
  if (!existsSync(modPath)) {
    return [];
  }
  const raw: unknown = JSON.parse(readFileSync(modPath, "utf8"));
  if (!isRecord(raw) || !Array.isArray(raw.modules)) {
    return [];
  }
  const out: ModuleDef[] = [];
  for (const item of raw.modules) {
    if (!isRecord(item) || typeof item.id !== "string") {
      continue;
    }
    out.push({
      id: item.id,
      name: typeof item.name === "string" ? item.name : item.id,
      description: typeof item.description === "string" ? item.description : "",
      paths: Array.isArray(item.paths) ? item.paths.filter((x): x is string => typeof x === "string") : [],
      aliases: Array.isArray(item.aliases) ? item.aliases.filter((x): x is string => typeof x === "string") : []
    });
  }
  return out;
}

function readArtifactModuleMap(ryugiDir: string): Map<string, string[]> {
  const map = new Map<string, string[]>();
  const cfgPath = join(ryugiDir, "config.json");
  if (!existsSync(cfgPath)) {
    return map;
  }
  const raw: unknown = JSON.parse(readFileSync(cfgPath, "utf8"));
  if (!isRecord(raw) || !isRecord(raw.artifacts)) {
    return map;
  }
  for (const [key, val] of Object.entries(raw.artifacts)) {
    if (isRecord(val) && Array.isArray(val.modules)) {
      map.set(
        key,
        val.modules.filter((m): m is string => typeof m === "string")
      );
    }
  }
  return map;
}

function scanArtifacts(ryugiDir: string, moduleMap: Map<string, string[]>): SyncArtifact[] {
  const artifactsRoot = join(ryugiDir, "artifacts");
  if (!existsSync(artifactsRoot)) {
    return [];
  }

  const results: SyncArtifact[] = [];
  for (const typeName of readdirSync(artifactsRoot)) {
    if (typeName.startsWith(".")) {
      continue;
    }
    const typeDir = join(artifactsRoot, typeName);
    if (!statSync(typeDir).isDirectory()) {
      continue;
    }
    for (const slug of readdirSync(typeDir)) {
      if (slug.startsWith(".")) {
        continue;
      }
      const slugDir = join(typeDir, slug);
      if (!statSync(slugDir).isDirectory()) {
        continue;
      }

      const key = `${typeName}/${slug}`;
      const modules = moduleMap.get(key) ?? [];

      if (typeName === "document") {
        const xmlPath = join(slugDir, "doc.xml");
        if (!existsSync(xmlPath)) {
          continue;
        }
        const content = readFileSync(xmlPath, "utf8");
        results.push({
          type: "document",
          slug,
          title: extractXmlTitle(content, slug),
          content,
          modules,
          meta: { source_file: "doc.xml" },
          render_png_b64: null,
          note: "Synced doc.xml from local workspace"
        });
      } else if (typeName === "whiteboard") {
        const scenePath = join(slugDir, "scene.excalidraw");
        if (!existsSync(scenePath)) {
          continue;
        }
        const content = readFileSync(scenePath, "utf8");
        const renderPath = join(artifactsRoot, ".state", "whiteboard", slug, "pages", "main", "render.png");
        const renderPngB64 = existsSync(renderPath) ? readFileSync(renderPath).toString("base64") : null;
        results.push({
          type: "whiteboard",
          slug,
          title: extractWhiteboardTitle(content, slug),
          content,
          modules,
          meta: { source_file: "scene.excalidraw", has_local_render: Boolean(renderPngB64) },
          render_png_b64: renderPngB64,
          note: "Synced scene.excalidraw from local workspace"
        });
      } else {
        const files = readdirSync(slugDir).filter((f) => !f.startsWith("."));
        const primary = files.find((f) => /\.(html|xml|json)$/i.test(f));
        if (!primary) {
          continue;
        }
        const content = readFileSync(join(slugDir, primary), "utf8");
        results.push({
          type: typeName,
          slug,
          title: slug,
          content,
          modules,
          meta: { source_file: primary },
          render_png_b64: null,
          note: `Synced ${primary} from local workspace`
        });
      }
    }
  }
  return results;
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  if (!args.url) {
    console.error("Usage: bun run scripts/sync.ts -- --url https://ryugi-hub.<subdomain>.workers.dev [--dir /path/to/repo] [--project id] [--token secret]");
    process.exit(1);
  }

  const ryugiDir = join(args.dir, ".ryugi");
  if (!existsSync(ryugiDir)) {
    console.error(`No .ryugi directory found at ${ryugiDir}`);
    process.exit(1);
  }

  const modules = readModules(ryugiDir);
  const moduleMap = readArtifactModuleMap(ryugiDir);
  const artifacts = scanArtifacts(ryugiDir, moduleMap);

  const payload = {
    project: {
      id: args.project,
      name: args.project,
      repo_path: args.dir,
      description: `Synced from ${args.dir}`
    },
    modules,
    artifacts
  };

  const headers: Record<string, string> = {
    "content-type": "application/json"
  };
  if (args.token) {
    headers.authorization = `Bearer ${args.token}`;
  }

  const res = await fetch(`${args.url}/api/sync`, {
    method: "POST",
    headers,
    body: JSON.stringify(payload)
  });

  const text = await res.text();
  if (!res.ok) {
    console.error(`Sync failed (HTTP ${res.status}): ${text}`);
    process.exit(1);
  }

  console.log(`Synced to ${args.url}: ${text}`);
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : String(err));
  process.exit(1);
});
