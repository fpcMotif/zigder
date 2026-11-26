export interface Env {
  DB: D1Database;
  ASSETS: Fetcher;
  ADMIN_TOKEN?: string;
}

interface JsonRecord {
  [key: string]: unknown;
}

interface ModuleInput {
  id: string;
  name: string;
  description: string;
  paths: string[];
  aliases: string[];
}

interface ArtifactInput {
  type: string;
  slug: string;
  title: string;
  content: string;
  modules: string[];
  meta: JsonRecord;
  render_png_b64: string | null;
  note: string;
}

function isRecord(value: unknown): value is JsonRecord {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function asString(value: unknown, fallback = ""): string {
  return typeof value === "string" ? value : fallback;
}

function asOptionalString(value: unknown): string | null {
  return typeof value === "string" ? value : null;
}

function asNumber(value: unknown, fallback = 0): number {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

function asBoolean(value: unknown, fallback = false): boolean {
  return typeof value === "boolean" ? value : fallback;
}

function asStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) {
    return [];
  }
  const out: string[] = [];
  for (const item of value) {
    if (typeof item === "string") {
      out.push(item);
    }
  }
  return out;
}

function parseJsonArrayStrings(raw: unknown): string[] {
  if (typeof raw !== "string" || raw.length === 0) {
    return [];
  }
  try {
    return asStringArray(JSON.parse(raw));
  } catch {
    return [];
  }
}

function parseJsonObject(raw: unknown): JsonRecord {
  if (typeof raw !== "string" || raw.length === 0) {
    return {};
  }
  try {
    const parsed: unknown = JSON.parse(raw);
    return isRecord(parsed) ? parsed : {};
  } catch {
    return {};
  }
}

function jsonResponse(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store"
    }
  });
}

function errorResponse(message: string, status: number): Response {
  return jsonResponse({ ok: false, error: message }, status);
}

async function readJsonBody(request: Request): Promise<JsonRecord | null> {
  try {
    const raw: unknown = await request.json();
    return isRecord(raw) ? raw : null;
  } catch {
    return null;
  }
}

function checkWriteAuth(request: Request, env: Env): boolean {
  const token = env.ADMIN_TOKEN;
  if (!token || token.length === 0) {
    return true;
  }
  const method = request.method.toUpperCase();
  if (method === "GET" || method === "HEAD" || method === "OPTIONS") {
    return true;
  }
  const auth = request.headers.get("authorization") ?? "";
  return auth === `Bearer ${token}`;
}

function decodeBase64ToBytes(b64: string): Uint8Array {
  const clean = b64.includes(",") ? b64.slice(b64.indexOf(",") + 1) : b64;
  const bin = atob(clean);
  const len = bin.length;
  const bytes = new Uint8Array(len);
  for (let i = 0; i < len; i += 1) {
    bytes[i] = bin.charCodeAt(i);
  }
  return bytes;
}

function makeArtifactId(projectId: string, type: string, slug: string): string {
  return `${projectId}:${type}:${slug}`;
}

function sanitizeSlug(raw: string): string {
  return raw
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

function normalizeModulesInput(raw: unknown): ModuleInput[] {
  if (!Array.isArray(raw)) {
    return [];
  }
  const out: ModuleInput[] = [];
  for (const item of raw) {
    if (!isRecord(item)) {
      continue;
    }
    const id = sanitizeSlug(asString(item.id));
    if (id.length === 0) {
      continue;
    }
    out.push({
      id,
      name: asString(item.name, id),
      description: asString(item.description),
      paths: asStringArray(item.paths),
      aliases: asStringArray(item.aliases)
    });
  }
  return out;
}

function normalizeArtifactInput(item: unknown): ArtifactInput | null {
  if (!isRecord(item)) {
    return null;
  }
  const type = sanitizeSlug(asString(item.type));
  const slug = sanitizeSlug(asString(item.slug));
  if (type.length === 0 || slug.length === 0) {
    return null;
  }
  const title = asString(item.title, slug);
  const content = asString(item.content);
  const modules = asStringArray(item.modules);
  const meta = isRecord(item.meta) ? item.meta : {};
  const renderPng = asOptionalString(item.render_png_b64);
  const note = asString(item.note);
  return {
    type,
    slug,
    title,
    content,
    modules,
    meta,
    render_png_b64: renderPng && renderPng.length > 0 ? renderPng : null,
    note
  };
}

function mapArtifactRow(row: JsonRecord, includeContent: boolean): JsonRecord {
  const mapped: JsonRecord = {
    id: asString(row.id),
    project_id: asString(row.project_id),
    type: asString(row.type),
    slug: asString(row.slug),
    title: asString(row.title),
    modules: parseJsonArrayStrings(row.modules_json),
    meta: parseJsonObject(row.meta_json),
    has_render: asNumber(row.has_render) === 1,
    revision: asNumber(row.revision, 1),
    byte_length: asNumber(row.byte_length),
    created_at: asString(row.created_at),
    updated_at: asString(row.updated_at),
    comment_count: asNumber(row.comment_count),
    ask_count: asNumber(row.ask_count)
  };
  if (includeContent) {
    mapped.content = asString(row.content);
  }
  return mapped;
}

async function fetchFullArtifact(env: Env, id: string): Promise<JsonRecord | null> {
  const row = await env.DB.prepare(
    `SELECT id, project_id, type, slug, title, content, modules_json, meta_json,
            CASE WHEN render_png_b64 IS NOT NULL AND render_png_b64 != '' THEN 1 ELSE 0 END AS has_render,
            revision, LENGTH(content) AS byte_length, created_at, updated_at
     FROM artifacts WHERE id = ?`
  )
    .bind(id)
    .first();

  if (!row || !isRecord(row)) {
    return null;
  }

  const [revRes, askRes, comRes] = await env.DB.batch([
    env.DB.prepare(
      `SELECT id, revision, note, LENGTH(content) AS byte_length, created_at
       FROM artifact_revisions WHERE artifact_id = ? ORDER BY revision DESC LIMIT 30`
    ).bind(id),
    env.DB.prepare(
      `SELECT ask_id, choice_value, response_text, updated_at
       FROM ask_responses WHERE artifact_id = ? ORDER BY ask_id ASC`
    ).bind(id),
    env.DB.prepare(
      `SELECT id, artifact_id, author, body, resolved, created_at
       FROM comments WHERE artifact_id = ? ORDER BY created_at DESC, id DESC`
    ).bind(id)
  ]);

  const revisions = (revRes?.results ?? []).map((r) => {
    const rec = isRecord(r) ? r : {};
    return {
      id: asNumber(rec.id),
      revision: asNumber(rec.revision),
      note: asString(rec.note),
      byte_length: asNumber(rec.byte_length),
      created_at: asString(rec.created_at)
    };
  });

  const askResponses: JsonRecord = {};
  for (const a of askRes?.results ?? []) {
    if (!isRecord(a)) {
      continue;
    }
    const askId = asString(a.ask_id);
    if (askId.length > 0) {
      askResponses[askId] = {
        ask_id: askId,
        choice_value: asOptionalString(a.choice_value),
        response_text: asOptionalString(a.response_text),
        updated_at: asString(a.updated_at)
      };
    }
  }

  const comments = (comRes?.results ?? []).map((c) => {
    const rec = isRecord(c) ? c : {};
    return {
      id: asNumber(rec.id),
      artifact_id: asString(rec.artifact_id),
      author: asString(rec.author),
      body: asString(rec.body),
      resolved: asNumber(rec.resolved) === 1,
      created_at: asString(rec.created_at)
    };
  });

  return {
    id: asString(row.id),
    project_id: asString(row.project_id),
    type: asString(row.type),
    slug: asString(row.slug),
    title: asString(row.title),
    content: asString(row.content),
    modules: parseJsonArrayStrings(row.modules_json),
    meta: parseJsonObject(row.meta_json),
    has_render: asNumber(row.has_render) === 1,
    revision: asNumber(row.revision, 1),
    byte_length: asNumber(row.byte_length),
    created_at: asString(row.created_at),
    updated_at: asString(row.updated_at),
    revisions,
    ask_responses: askResponses,
    comments
  };
}

async function handleHealth(env: Env): Promise<Response> {
  const row = await env.DB.prepare(
    `SELECT
      (SELECT COUNT(*) FROM projects) AS projects,
      (SELECT COUNT(*) FROM modules) AS modules,
      (SELECT COUNT(*) FROM artifacts) AS artifacts,
      (SELECT COUNT(*) FROM comments) AS comments,
      (SELECT COUNT(*) FROM ask_responses) AS ask_responses`
  ).first();

  const rec = isRecord(row) ? row : {};
  return jsonResponse({
    ok: true,
    db: "connected",
    plan: "free-tier",
    auth_required: Boolean(env.ADMIN_TOKEN && env.ADMIN_TOKEN.length > 0),
    counts: {
      projects: asNumber(rec.projects),
      modules: asNumber(rec.modules),
      artifacts: asNumber(rec.artifacts),
      comments: asNumber(rec.comments),
      ask_responses: asNumber(rec.ask_responses)
    }
  });
}

async function handleListProjects(env: Env): Promise<Response> {
  const res = await env.DB.prepare(
    `SELECT p.id, p.name, p.repo_path, p.description, p.created_at, p.updated_at,
            (SELECT COUNT(*) FROM modules m WHERE m.project_id = p.id) AS module_count,
            (SELECT COUNT(*) FROM artifacts a WHERE a.project_id = p.id) AS artifact_count
     FROM projects p
     ORDER BY p.updated_at DESC, p.id ASC`
  ).all();

  const projects = (res.results ?? []).map((row) => {
    const rec = isRecord(row) ? row : {};
    return {
      id: asString(rec.id),
      name: asString(rec.name),
      repo_path: asString(rec.repo_path),
      description: asString(rec.description),
      created_at: asString(rec.created_at),
      updated_at: asString(rec.updated_at),
      module_count: asNumber(rec.module_count),
      artifact_count: asNumber(rec.artifact_count)
    };
  });

  return jsonResponse({ ok: true, projects });
}

async function handleUpsertProject(request: Request, env: Env): Promise<Response> {
  const body = await readJsonBody(request);
  if (!body) {
    return errorResponse("Invalid JSON body", 400);
  }
  const id = sanitizeSlug(asString(body.id));
  if (id.length === 0) {
    return errorResponse("Project id is required", 400);
  }
  const name = asString(body.name, id).trim() || id;
  const repoPath = asString(body.repo_path);
  const description = asString(body.description);
  const now = new Date().toISOString();

  await env.DB.prepare(
    `INSERT INTO projects (id, name, repo_path, description, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?)
     ON CONFLICT(id) DO UPDATE SET
       name = excluded.name,
       repo_path = CASE WHEN excluded.repo_path != '' THEN excluded.repo_path ELSE projects.repo_path END,
       description = CASE WHEN excluded.description != '' THEN excluded.description ELSE projects.description END,
       updated_at = excluded.updated_at`
  )
    .bind(id, name, repoPath, description, now, now)
    .run();

  return jsonResponse({
    ok: true,
    project: { id, name, repo_path: repoPath, description, updated_at: now }
  });
}

async function handleListModules(env: Env, projectId: string): Promise<Response> {
  const res = await env.DB.prepare(
    `SELECT project_id, id, name, description, paths_json, aliases_json
     FROM modules WHERE project_id = ? ORDER BY id ASC`
  )
    .bind(projectId)
    .all();

  const modules = (res.results ?? []).map((row) => {
    const rec = isRecord(row) ? row : {};
    return {
      project_id: asString(rec.project_id),
      id: asString(rec.id),
      name: asString(rec.name),
      description: asString(rec.description),
      paths: parseJsonArrayStrings(rec.paths_json),
      aliases: parseJsonArrayStrings(rec.aliases_json)
    };
  });

  return jsonResponse({ ok: true, project_id: projectId, modules });
}

async function handleReplaceModules(request: Request, env: Env, projectId: string): Promise<Response> {
  const body = await readJsonBody(request);
  if (!body) {
    return errorResponse("Invalid JSON body", 400);
  }
  const modules = normalizeModulesInput(body.modules);
  const now = new Date().toISOString();

  const stmts: D1PreparedStatement[] = [
    env.DB.prepare(
      `INSERT INTO projects (id, name, repo_path, description, created_at, updated_at)
       VALUES (?, ?, '', '', ?, ?)
       ON CONFLICT(id) DO UPDATE SET updated_at = excluded.updated_at`
    ).bind(projectId, projectId, now, now),
    env.DB.prepare(`DELETE FROM modules WHERE project_id = ?`).bind(projectId)
  ];

  for (const mod of modules) {
    stmts.push(
      env.DB.prepare(
        `INSERT INTO modules (project_id, id, name, description, paths_json, aliases_json)
         VALUES (?, ?, ?, ?, ?, ?)`
      ).bind(
        projectId,
        mod.id,
        mod.name,
        mod.description,
        JSON.stringify(mod.paths),
        JSON.stringify(mod.aliases)
      )
    );
  }

  await env.DB.batch(stmts);
  return jsonResponse({ ok: true, project_id: projectId, count: modules.length, modules });
}

async function handleListArtifacts(url: URL, env: Env): Promise<Response> {
  const project = url.searchParams.get("project")?.trim() ?? "";
  const type = url.searchParams.get("type")?.trim() ?? "";
  const moduleFilter = url.searchParams.get("module")?.trim() ?? "";
  const query = url.searchParams.get("q")?.trim().toLowerCase() ?? "";
  const includeContent = url.searchParams.get("include_content") === "1";

  const where: string[] = [];
  const binds: unknown[] = [];

  if (project.length > 0) {
    where.push("a.project_id = ?");
    binds.push(project);
  }
  if (type.length > 0) {
    where.push("a.type = ?");
    binds.push(type);
  }

  const whereSql = where.length > 0 ? `WHERE ${where.join(" AND ")}` : "";
  const contentSelect = includeContent ? ", a.content" : "";

  const sql = `SELECT a.id, a.project_id, a.type, a.slug, a.title${contentSelect},
                      a.modules_json, a.meta_json,
                      CASE WHEN a.render_png_b64 IS NOT NULL AND a.render_png_b64 != '' THEN 1 ELSE 0 END AS has_render,
                      a.revision, LENGTH(a.content) AS byte_length, a.created_at, a.updated_at,
                      (SELECT COUNT(*) FROM comments c WHERE c.artifact_id = a.id) AS comment_count,
                      (SELECT COUNT(*) FROM ask_responses k WHERE k.artifact_id = a.id) AS ask_count
               FROM artifacts a
               ${whereSql}
               ORDER BY a.updated_at DESC, a.slug ASC`;

  const stmt = binds.length > 0 ? env.DB.prepare(sql).bind(...binds) : env.DB.prepare(sql);
  const res = await stmt.all();

  let artifacts = (res.results ?? []).map((row) =>
    mapArtifactRow(isRecord(row) ? row : {}, includeContent)
  );

  if (moduleFilter.length > 0) {
    artifacts = artifacts.filter((art) => {
      const mods = asStringArray(art.modules);
      return mods.includes(moduleFilter);
    });
  }

  if (query.length > 0) {
    artifacts = artifacts.filter((art) => {
      const title = asString(art.title).toLowerCase();
      const slug = asString(art.slug).toLowerCase();
      const mods = asStringArray(art.modules).join(" ").toLowerCase();
      const artType = asString(art.type).toLowerCase();
      return (
        title.includes(query) ||
        slug.includes(query) ||
        mods.includes(query) ||
        artType.includes(query)
      );
    });
  }

  return jsonResponse({ ok: true, artifacts });
}

async function handleCreateArtifact(request: Request, env: Env): Promise<Response> {
  const body = await readJsonBody(request);
  if (!body) {
    return errorResponse("Invalid JSON body", 400);
  }

  const projectId = sanitizeSlug(asString(body.project_id, "zigder"));
  const input = normalizeArtifactInput(body);
  if (projectId.length === 0 || !input) {
    return errorResponse("project_id, type, and slug are required", 400);
  }

  const id = makeArtifactId(projectId, input.type, input.slug);
  const existing = await env.DB.prepare(`SELECT id FROM artifacts WHERE id = ?`).bind(id).first();
  if (existing) {
    return errorResponse(`Artifact already exists: ${id}`, 409);
  }

  const now = new Date().toISOString();
  const note = input.note || "Created in Ryugi Hub";

  await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO projects (id, name, repo_path, description, created_at, updated_at)
       VALUES (?, ?, '', '', ?, ?)
       ON CONFLICT(id) DO UPDATE SET updated_at = excluded.updated_at`
    ).bind(projectId, projectId, now, now),
    env.DB.prepare(
      `INSERT INTO artifacts (id, project_id, type, slug, title, content, modules_json, meta_json, render_png_b64, revision, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)`
    ).bind(
      id,
      projectId,
      input.type,
      input.slug,
      input.title,
      input.content,
      JSON.stringify(input.modules),
      JSON.stringify(input.meta),
      input.render_png_b64,
      now,
      now
    ),
    env.DB.prepare(
      `INSERT INTO artifact_revisions (artifact_id, revision, content, note, created_at)
       VALUES (?, 1, ?, ?, ?)`
    ).bind(id, input.content, note, now)
  ]);

  const created = await fetchFullArtifact(env, id);
  return jsonResponse({ ok: true, artifact: created }, 201);
}

async function handleUpdateArtifact(request: Request, env: Env, id: string): Promise<Response> {
  const body = await readJsonBody(request);
  if (!body) {
    return errorResponse("Invalid JSON body", 400);
  }

  const current = await env.DB.prepare(
    `SELECT id, title, content, modules_json, meta_json, render_png_b64, revision
     FROM artifacts WHERE id = ?`
  )
    .bind(id)
    .first();

  if (!current || !isRecord(current)) {
    return errorResponse("Artifact not found", 404);
  }

  const currentContent = asString(current.content);
  const nextTitle = asString(body.title, asString(current.title));
  const nextContent = body.content !== undefined ? asString(body.content) : currentContent;
  const nextModules =
    body.modules !== undefined
      ? JSON.stringify(asStringArray(body.modules))
      : asString(current.modules_json, "[]");
  const nextMeta =
    body.meta !== undefined && isRecord(body.meta)
      ? JSON.stringify(body.meta)
      : asString(current.meta_json, "{}");
  const nextRender =
    body.render_png_b64 !== undefined
      ? asOptionalString(body.render_png_b64)
      : asOptionalString(current.render_png_b64);

  const contentChanged = nextContent !== currentContent;
  const nextRevision = contentChanged ? asNumber(current.revision, 1) + 1 : asNumber(current.revision, 1);
  const now = new Date().toISOString();
  const note = asString(body.note, contentChanged ? "Updated via web editor" : "Metadata updated");

  const stmts: D1PreparedStatement[] = [
    env.DB.prepare(
      `UPDATE artifacts
       SET title = ?, content = ?, modules_json = ?, meta_json = ?, render_png_b64 = ?, revision = ?, updated_at = ?
       WHERE id = ?`
    ).bind(nextTitle, nextContent, nextModules, nextMeta, nextRender, nextRevision, now, id)
  ];

  if (contentChanged) {
    stmts.push(
      env.DB.prepare(
        `INSERT INTO artifact_revisions (artifact_id, revision, content, note, created_at)
         VALUES (?, ?, ?, ?, ?)`
      ).bind(id, nextRevision, nextContent, note, now)
    );
  }

  await env.DB.batch(stmts);
  const updated = await fetchFullArtifact(env, id);
  return jsonResponse({ ok: true, artifact: updated });
}

async function handleDeleteArtifact(env: Env, id: string): Promise<Response> {
  const existing = await env.DB.prepare(`SELECT id FROM artifacts WHERE id = ?`).bind(id).first();
  if (!existing) {
    return errorResponse("Artifact not found", 404);
  }
  await env.DB.batch([
    env.DB.prepare(`DELETE FROM comments WHERE artifact_id = ?`).bind(id),
    env.DB.prepare(`DELETE FROM ask_responses WHERE artifact_id = ?`).bind(id),
    env.DB.prepare(`DELETE FROM artifact_revisions WHERE artifact_id = ?`).bind(id),
    env.DB.prepare(`DELETE FROM artifacts WHERE id = ?`).bind(id)
  ]);
  return jsonResponse({ ok: true, deleted_id: id });
}

async function handleRestoreRevision(request: Request, env: Env, id: string): Promise<Response> {
  const body = await readJsonBody(request);
  if (!body) {
    return errorResponse("Invalid JSON body", 400);
  }
  const targetRev = asNumber(body.revision, -1);
  if (targetRev < 1) {
    return errorResponse("Valid revision number is required", 400);
  }

  const [artRow, revRow] = await env.DB.batch([
    env.DB.prepare(`SELECT revision FROM artifacts WHERE id = ?`).bind(id),
    env.DB.prepare(
      `SELECT content FROM artifact_revisions WHERE artifact_id = ? AND revision = ? LIMIT 1`
    ).bind(id, targetRev)
  ]);

  const current = artRow?.results?.[0];
  const rev = revRow?.results?.[0];
  if (!current || !isRecord(current)) {
    return errorResponse("Artifact not found", 404);
  }
  if (!rev || !isRecord(rev)) {
    return errorResponse(`Revision ${targetRev} not found`, 404);
  }

  const restoredContent = asString(rev.content);
  const nextRevision = asNumber(current.revision, 1) + 1;
  const now = new Date().toISOString();

  await env.DB.batch([
    env.DB.prepare(`UPDATE artifacts SET content = ?, revision = ?, updated_at = ? WHERE id = ?`).bind(
      restoredContent,
      nextRevision,
      now,
      id
    ),
    env.DB.prepare(
      `INSERT INTO artifact_revisions (artifact_id, revision, content, note, created_at)
       VALUES (?, ?, ?, ?, ?)`
    ).bind(id, nextRevision, restoredContent, `Restored from r${targetRev}`, now)
  ]);

  const updated = await fetchFullArtifact(env, id);
  return jsonResponse({ ok: true, artifact: updated });
}

async function handleGetRenderPng(env: Env, id: string): Promise<Response> {
  const row = await env.DB.prepare(`SELECT render_png_b64 FROM artifacts WHERE id = ?`).bind(id).first();
  if (!row || !isRecord(row)) {
    return errorResponse("Artifact not found", 404);
  }
  const b64 = asOptionalString(row.render_png_b64);
  if (!b64 || b64.length === 0) {
    return errorResponse("Render PNG not stored for this artifact", 404);
  }
  const bytes = decodeBase64ToBytes(b64);
  return new Response(bytes, {
    status: 200,
    headers: {
      "content-type": "image/png",
      "cache-control": "public, max-age=60"
    }
  });
}

async function handleSaveAskResponse(
  request: Request,
  env: Env,
  id: string,
  askId: string
): Promise<Response> {
  const body = await readJsonBody(request);
  if (!body) {
    return errorResponse("Invalid JSON body", 400);
  }

  const existing = await env.DB.prepare(`SELECT id FROM artifacts WHERE id = ?`).bind(id).first();
  if (!existing) {
    return errorResponse("Artifact not found", 404);
  }

  const choiceValue = asOptionalString(body.choice_value);
  const responseText = asOptionalString(body.response_text);
  const now = new Date().toISOString();

  await env.DB.prepare(
    `INSERT INTO ask_responses (artifact_id, ask_id, choice_value, response_text, updated_at)
     VALUES (?, ?, ?, ?, ?)
     ON CONFLICT(artifact_id, ask_id) DO UPDATE SET
       choice_value = excluded.choice_value,
       response_text = excluded.response_text,
       updated_at = excluded.updated_at`
  )
    .bind(id, askId, choiceValue, responseText, now)
    .run();

  return jsonResponse({
    ok: true,
    ask_response: {
      artifact_id: id,
      ask_id: askId,
      choice_value: choiceValue,
      response_text: responseText,
      updated_at: now
    }
  });
}

async function handleAddComment(request: Request, env: Env, id: string): Promise<Response> {
  const body = await readJsonBody(request);
  if (!body) {
    return errorResponse("Invalid JSON body", 400);
  }

  const existing = await env.DB.prepare(`SELECT id FROM artifacts WHERE id = ?`).bind(id).first();
  if (!existing) {
    return errorResponse("Artifact not found", 404);
  }

  const author = asString(body.author, "Reviewer").trim() || "Reviewer";
  const text = asString(body.body).trim();
  if (text.length === 0) {
    return errorResponse("Comment body is required", 400);
  }
  const now = new Date().toISOString();

  const insertRes = await env.DB.prepare(
    `INSERT INTO comments (artifact_id, author, body, resolved, created_at)
     VALUES (?, ?, ?, 0, ?)`
  )
    .bind(id, author, text, now)
    .run();

  const commentId = asNumber(insertRes.meta?.last_row_id);
  return jsonResponse(
    {
      ok: true,
      comment: {
        id: commentId,
        artifact_id: id,
        author,
        body: text,
        resolved: false,
        created_at: now
      }
    },
    201
  );
}

async function handlePatchComment(request: Request, env: Env, commentId: number): Promise<Response> {
  const body = await readJsonBody(request);
  if (!body) {
    return errorResponse("Invalid JSON body", 400);
  }
  const resolved = asBoolean(body.resolved, true) ? 1 : 0;
  const res = await env.DB.prepare(`UPDATE comments SET resolved = ? WHERE id = ?`)
    .bind(resolved, commentId)
    .run();
  if (asNumber(res.meta?.changes) === 0) {
    return errorResponse("Comment not found", 404);
  }
  return jsonResponse({ ok: true, id: commentId, resolved: resolved === 1 });
}

async function handleDeleteComment(env: Env, commentId: number): Promise<Response> {
  const res = await env.DB.prepare(`DELETE FROM comments WHERE id = ?`).bind(commentId).run();
  if (asNumber(res.meta?.changes) === 0) {
    return errorResponse("Comment not found", 404);
  }
  return jsonResponse({ ok: true, deleted_id: commentId });
}

async function handleSync(request: Request, env: Env): Promise<Response> {
  const body = await readJsonBody(request);
  if (!body || !isRecord(body.project)) {
    return errorResponse("Invalid sync payload: project object is required", 400);
  }

  const projRec = body.project;
  const projectId = sanitizeSlug(asString(projRec.id));
  if (projectId.length === 0) {
    return errorResponse("project.id is required", 400);
  }

  const projectName = asString(projRec.name, projectId).trim() || projectId;
  const repoPath = asString(projRec.repo_path);
  const description = asString(projRec.description);
  const modules = normalizeModulesInput(body.modules);
  const rawArtifacts = Array.isArray(body.artifacts) ? body.artifacts : [];
  const artifacts: ArtifactInput[] = [];
  for (const item of rawArtifacts) {
    const parsed = normalizeArtifactInput(item);
    if (parsed) {
      artifacts.push(parsed);
    }
  }

  const now = new Date().toISOString();
  const existingRes = await env.DB.prepare(
    `SELECT id, title, content, modules_json, meta_json, render_png_b64, revision
     FROM artifacts WHERE project_id = ?`
  )
    .bind(projectId)
    .all();

  const existingById = new Map<string, JsonRecord>();
  for (const row of existingRes.results ?? []) {
    if (isRecord(row)) {
      existingById.set(asString(row.id), row);
    }
  }

  const stmts: D1PreparedStatement[] = [
    env.DB.prepare(
      `INSERT INTO projects (id, name, repo_path, description, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET
         name = excluded.name,
         repo_path = excluded.repo_path,
         description = excluded.description,
         updated_at = excluded.updated_at`
    ).bind(projectId, projectName, repoPath, description, now, now),
    env.DB.prepare(`DELETE FROM modules WHERE project_id = ?`).bind(projectId)
  ];

  for (const mod of modules) {
    stmts.push(
      env.DB.prepare(
        `INSERT INTO modules (project_id, id, name, description, paths_json, aliases_json)
         VALUES (?, ?, ?, ?, ?, ?)`
      ).bind(
        projectId,
        mod.id,
        mod.name,
        mod.description,
        JSON.stringify(mod.paths),
        JSON.stringify(mod.aliases)
      )
    );
  }

  let created = 0;
  let updated = 0;
  let unchanged = 0;

  for (const art of artifacts) {
    const id = makeArtifactId(projectId, art.type, art.slug);
    const modulesJson = JSON.stringify(art.modules);
    const metaJson = JSON.stringify(art.meta);
    const prev = existingById.get(id);

    if (!prev) {
      created += 1;
      stmts.push(
        env.DB.prepare(
          `INSERT INTO artifacts (id, project_id, type, slug, title, content, modules_json, meta_json, render_png_b64, revision, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)`
        ).bind(
          id,
          projectId,
          art.type,
          art.slug,
          art.title,
          art.content,
          modulesJson,
          metaJson,
          art.render_png_b64,
          now,
          now
        ),
        env.DB.prepare(
          `INSERT INTO artifact_revisions (artifact_id, revision, content, note, created_at)
           VALUES (?, 1, ?, ?, ?)`
        ).bind(id, art.content, art.note || "Synced from local workspace", now)
      );
      continue;
    }

    const prevContent = asString(prev.content);
    const prevTitle = asString(prev.title);
    const prevModules = asString(prev.modules_json);
    const prevMeta = asString(prev.meta_json);
    const prevRender = asOptionalString(prev.render_png_b64);
    const contentChanged = prevContent !== art.content;
    const renderChanged = (art.render_png_b64 ?? null) !== (prevRender ?? null);
    const metaChanged = prevTitle !== art.title || prevModules !== modulesJson || prevMeta !== metaJson;

    if (!contentChanged && !renderChanged && !metaChanged) {
      unchanged += 1;
      continue;
    }

    updated += 1;
    const nextRev = contentChanged ? asNumber(prev.revision, 1) + 1 : asNumber(prev.revision, 1);
    stmts.push(
      env.DB.prepare(
        `UPDATE artifacts
         SET title = ?, content = ?, modules_json = ?, meta_json = ?, render_png_b64 = ?, revision = ?, updated_at = ?
         WHERE id = ?`
      ).bind(
        art.title,
        art.content,
        modulesJson,
        metaJson,
        art.render_png_b64 ?? prevRender,
        nextRev,
        now,
        id
      )
    );

    if (contentChanged) {
      stmts.push(
        env.DB.prepare(
          `INSERT INTO artifact_revisions (artifact_id, revision, content, note, created_at)
           VALUES (?, ?, ?, ?, ?)`
        ).bind(id, nextRev, art.content, art.note || "Synced from local workspace", now)
      );
    }
  }

  for (let i = 0; i < stmts.length; i += 40) {
    await env.DB.batch(stmts.slice(i, i + 40));
  }

  return jsonResponse({
    ok: true,
    project_id: projectId,
    modules_synced: modules.length,
    artifacts_synced: artifacts.length,
    created,
    updated,
    unchanged
  });
}

async function routeApi(request: Request, env: Env, url: URL): Promise<Response> {
  if (!checkWriteAuth(request, env)) {
    return errorResponse("Unauthorized: Bearer ADMIN_TOKEN required for write operations", 401);
  }

  const method = request.method.toUpperCase();
  const path = url.pathname;

  if (path === "/api/health" && method === "GET") {
    return handleHealth(env);
  }

  if (path === "/api/projects" && method === "GET") {
    return handleListProjects(env);
  }

  if (path === "/api/projects" && method === "POST") {
    return handleUpsertProject(request, env);
  }

  const modMatch = path.match(/^\/api\/projects\/([^/]+)\/modules$/);
  if (modMatch) {
    const projectId = decodeURIComponent(modMatch[1]);
    if (method === "GET") {
      return handleListModules(env, projectId);
    }
    if (method === "PUT") {
      return handleReplaceModules(request, env, projectId);
    }
  }

  if (path === "/api/sync" && method === "POST") {
    return handleSync(request, env);
  }

  if (path === "/api/artifacts" && method === "GET") {
    return handleListArtifacts(url, env);
  }

  if (path === "/api/artifacts" && method === "POST") {
    return handleCreateArtifact(request, env);
  }

  if (path === "/api/artifacts/by-ref" && method === "GET") {
    const project = url.searchParams.get("project")?.trim() ?? "";
    const type = url.searchParams.get("type")?.trim() ?? "";
    const slug = url.searchParams.get("slug")?.trim() ?? "";
    if (!project || !type || !slug) {
      return errorResponse("project, type, and slug query parameters are required", 400);
    }
    const artifact = await fetchFullArtifact(env, makeArtifactId(project, type, slug));
    if (!artifact) {
      return errorResponse("Referenced artifact not found", 404);
    }
    return jsonResponse({ ok: true, artifact });
  }

  const renderMatch = path.match(/^\/api\/artifacts\/([^/]+)\/render\.png$/);
  if (renderMatch && method === "GET") {
    return handleGetRenderPng(env, decodeURIComponent(renderMatch[1]));
  }

  const restoreMatch = path.match(/^\/api\/artifacts\/([^/]+)\/restore$/);
  if (restoreMatch && method === "POST") {
    return handleRestoreRevision(request, env, decodeURIComponent(restoreMatch[1]));
  }

  const askMatch = path.match(/^\/api\/artifacts\/([^/]+)\/asks\/([^/]+)$/);
  if (askMatch && method === "POST") {
    return handleSaveAskResponse(
      request,
      env,
      decodeURIComponent(askMatch[1]),
      decodeURIComponent(askMatch[2])
    );
  }

  const artCommentsMatch = path.match(/^\/api\/artifacts\/([^/]+)\/comments$/);
  if (artCommentsMatch && method === "POST") {
    return handleAddComment(request, env, decodeURIComponent(artCommentsMatch[1]));
  }

  const artMatch = path.match(/^\/api\/artifacts\/([^/]+)$/);
  if (artMatch) {
    const id = decodeURIComponent(artMatch[1]);
    if (method === "GET") {
      const artifact = await fetchFullArtifact(env, id);
      if (!artifact) {
        return errorResponse("Artifact not found", 404);
      }
      return jsonResponse({ ok: true, artifact });
    }
    if (method === "PUT") {
      return handleUpdateArtifact(request, env, id);
    }
    if (method === "DELETE") {
      return handleDeleteArtifact(env, id);
    }
  }

  const commentMatch = path.match(/^\/api\/comments\/(\d+)$/);
  if (commentMatch) {
    const commentId = Number(commentMatch[1]);
    if (method === "PATCH") {
      return handlePatchComment(request, env, commentId);
    }
    if (method === "DELETE") {
      return handleDeleteComment(env, commentId);
    }
  }

  return errorResponse("API route not found", 404);
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname.startsWith("/api/")) {
      try {
        return await routeApi(request, env, url);
      } catch (err) {
        const message = err instanceof Error ? err.message : "Unexpected server error";
        return errorResponse(message, 500);
      }
    }
    return env.ASSETS.fetch(request);
  }
};
