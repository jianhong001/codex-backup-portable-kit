#!/usr/bin/osascript -l JavaScript

ObjC.import('Foundation');

const app = Application.currentApplication();
app.includeStandardAdditions = true;

function environmentValue(name) {
  const value = $.NSProcessInfo.processInfo.environment.objectForKey($(name));
  return value ? ObjC.unwrap(value) : '';
}

function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function readText(path) {
  const data = $.NSData.dataWithContentsOfFile($(path));
  if (!data) {
    throw new Error(`Cannot read ${path}`);
  }
  const text = $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding);
  if (!text) {
    throw new Error(`Cannot decode ${path} as UTF-8`);
  }
  return ObjC.unwrap(text);
}

function writeText(path, text) {
  const content = $.NSString.stringWithString($(text));
  const data = content.dataUsingEncoding($.NSUTF8StringEncoding);
  if (!data.writeToFileAtomically($(path), true)) {
    throw new Error(`Cannot write ${path}`);
  }
}

function readJsonIfPresent(path) {
  if (!path || !$.NSFileManager.defaultManager.fileExistsAtPath($(path))) {
    return {};
  }
  const parsed = JSON.parse(readText(path));
  if (!isObject(parsed)) {
    throw new Error(`Expected a JSON object in ${path}`);
  }
  return parsed;
}

function asObject(parent, key) {
  if (!isObject(parent[key])) {
    parent[key] = {};
  }
  return parent[key];
}

function asArray(parent, key) {
  if (!Array.isArray(parent[key])) {
    parent[key] = [];
  }
  return parent[key];
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, "'\\''")}'`;
}

function sha256(value) {
  const output = app.doShellScript(
    `/usr/bin/printf %s ${shellQuote(value)} | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'`
  );
  const hash = output.trim().split(/\s+/)[0];
  if (!/^[0-9a-f]{64}$/i.test(hash)) {
    throw new Error('Cannot create a stable project ID');
  }
  return hash.toLowerCase();
}

function deterministicUuid(seed) {
  const hash = sha256(seed);
  const variant = '89ab'[parseInt(hash[16], 16) % 4];
  return `${hash.slice(0, 8)}-${hash.slice(8, 12)}-4${hash.slice(13, 16)}-${variant}${hash.slice(17, 20)}-${hash.slice(20, 32)}`;
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function uniqueStrings(values) {
  const seen = {};
  return values.filter((value) => {
    if (typeof value !== 'string' || !value || seen[value]) {
      return false;
    }
    seen[value] = true;
    return true;
  });
}

function basename(path) {
  const stripped = String(path || '').replace(/\/+$/, '');
  const separator = stripped.lastIndexOf('/');
  return separator >= 0 ? stripped.slice(separator + 1) : stripped;
}

function safeFolderName(value) {
  const normalized = String(value || '')
    .replace(/[\0-\x1f/:]/g, '-')
    .replace(/^\s+|\s+$/g, '')
    .replace(/[. ]+$/g, '');
  return normalized || '旧 Mac 项目';
}

function joinPath(...parts) {
  return parts
    .filter((part) => typeof part === 'string' && part.length > 0)
    .join('/')
    .replace(/\/+/g, '/');
}

function parseTsv(path, minimumColumns) {
  if (!path || !$.NSFileManager.defaultManager.fileExistsAtPath($(path))) {
    return [];
  }
  return readText(path)
    .split(/\r?\n/)
    .filter((line) => line.length > 0)
    .map((line) => {
      const columns = line.split('\t');
      if (columns.length < minimumColumns) {
        throw new Error(`Invalid TSV row in ${path}`);
      }
      return columns;
    });
}

const sourceGlobalPath = environmentValue('CODEX_PROJECT_LAYOUT_SOURCE_GLOBAL');
const targetGlobalPath = environmentValue('CODEX_PROJECT_LAYOUT_TARGET_GLOBAL');
const importMapPath = environmentValue('CODEX_PROJECT_LAYOUT_IMPORT_MAP');
const sourceCwdPath = environmentValue('CODEX_PROJECT_LAYOUT_SOURCE_CWDS');
const outputLayoutPath = environmentValue('CODEX_PROJECT_LAYOUT_OUTPUT_MAP');
const outputSummaryPath = environmentValue('CODEX_PROJECT_LAYOUT_SUMMARY');
const oldHome = environmentValue('CODEX_PROJECT_LAYOUT_OLD_HOME');
const newHome = environmentValue('CODEX_PROJECT_LAYOUT_NEW_HOME');
const projectsRoot = environmentValue('CODEX_PROJECT_LAYOUT_PROJECTS_ROOT');
const sourceComputerName = environmentValue('CODEX_PROJECT_LAYOUT_COMPUTER_NAME') || '旧 Mac';

if (!targetGlobalPath || !importMapPath || !outputLayoutPath || !outputSummaryPath || !newHome || !projectsRoot) {
  throw new Error('Project layout helper is missing required inputs');
}

const sourceState = readJsonIfPresent(sourceGlobalPath);
const targetState = readJsonIfPresent(targetGlobalPath);
const sourceProjects = isObject(sourceState['local-projects']) ? sourceState['local-projects'] : {};
const sourceAssignments = isObject(sourceState['thread-project-assignments']) ? sourceState['thread-project-assignments'] : {};
const sourceHints = isObject(sourceState['thread-workspace-root-hints']) ? sourceState['thread-workspace-root-hints'] : {};
const sourceOrders = isObject(sourceState['sidebar-project-thread-orders']) ? sourceState['sidebar-project-thread-orders'] : {};
const sourceProjectOrder = Array.isArray(sourceState['project-order']) ? sourceState['project-order'] : [];
const targetProjects = asObject(targetState, 'local-projects');
const targetAssignments = asObject(targetState, 'thread-project-assignments');
const targetHints = asObject(targetState, 'thread-workspace-root-hints');
const targetOrders = asObject(targetState, 'sidebar-project-thread-orders');
const targetProjectOrder = asArray(targetState, 'project-order');
const targetProjectless = asArray(targetState, 'projectless-thread-ids');
const targetSavedRoots = asArray(targetState, 'electron-saved-workspace-roots');

function rebasePath(path) {
  if (typeof path !== 'string' || !path) {
    return '';
  }
  if (oldHome && (path === oldHome || path.startsWith(`${oldHome}/`))) {
    return `${newHome}${path.slice(oldHome.length)}`;
  }
  return path;
}

const sourceCwds = {};
for (const row of parseTsv(sourceCwdPath, 2)) {
  sourceCwds[row[0]] = row.slice(1).join('\t');
}

const importRows = parseTsv(importMapPath, 5)
  .map((row) => ({
    targetId: row[0],
    sourceId: row[1],
    wasExisting: row[4],
  }))
  .filter((row) => row.wasExisting === '0');

const plans = {};
const planOrder = [];

function displayName(baseName) {
  const suffix = `（${sourceComputerName}）`;
  const name = String(baseName || '旧 Mac 项目');
  return name.endsWith(suffix) ? name : `${name}${suffix}`;
}

function projectRoots(project, fallbackCwd, projectKey) {
  const roots = isObject(project) && Array.isArray(project.rootPaths)
    ? project.rootPaths.map(rebasePath)
    : [];
  const fallback = rebasePath(fallbackCwd);
  const usable = uniqueStrings(roots);
  if (usable.length > 0) {
    return usable;
  }
  if (fallback) {
    return [fallback];
  }
  return [joinPath(projectsRoot, '旧 Mac 导入项目', safeFolderName(projectKey))];
}

function planFor(sourceProjectId, fallbackCwd) {
  const normalizedSourceId = sourceProjectId || '__ungrouped__';
  if (plans[normalizedSourceId]) {
    return plans[normalizedSourceId];
  }

  const sourceProject = isObject(sourceProjects[normalizedSourceId]) ? sourceProjects[normalizedSourceId] : {};
  const fallbackName = normalizedSourceId === '__ungrouped__'
    ? '旧 Mac 导入聊天'
    : (basename(fallbackCwd) || '旧 Mac 项目');
  const name = displayName(typeof sourceProject.name === 'string' && sourceProject.name ? sourceProject.name : fallbackName);
  const roots = projectRoots(sourceProject, fallbackCwd, fallbackName);
  const identity = `codex-backup-project:${sourceComputerName}:${normalizedSourceId}`;
  let targetProjectId = deterministicUuid(identity);
  let salt = 0;
  while (isObject(targetProjects[targetProjectId])) {
    const existing = targetProjects[targetProjectId];
    if (existing.name === name && JSON.stringify(existing.rootPaths || []) === JSON.stringify(roots)) {
      break;
    }
    salt += 1;
    targetProjectId = deterministicUuid(`${identity}:${salt}`);
  }

  if (!isObject(targetProjects[targetProjectId])) {
    const record = clone(sourceProject);
    record.id = targetProjectId;
    record.name = name;
    record.rootPaths = roots;
    record.createdAt = Date.now();
    record.updatedAt = Date.now();
    targetProjects[targetProjectId] = record;
  }
  if (!targetProjectOrder.includes(targetProjectId)) {
    targetProjectOrder.push(targetProjectId);
  }
  for (const root of roots) {
    if (!targetSavedRoots.includes(root)) {
      targetSavedRoots.push(root);
    }
  }

  const plan = {
    sourceProjectId: normalizedSourceId,
    targetProjectId,
    roots,
    targetIds: [],
    sourceToTarget: {},
  };
  plans[normalizedSourceId] = plan;
  planOrder.push(plan);
  return plan;
}

const layoutRows = [];
const importedTargetIds = {};
for (const row of importRows) {
  const sourceAssignment = isObject(sourceAssignments[row.sourceId]) ? sourceAssignments[row.sourceId] : {};
  const sourceCwd = typeof sourceAssignment.cwd === 'string' && sourceAssignment.cwd
    ? sourceAssignment.cwd
    : (sourceCwds[row.sourceId] || '');
  const sourceProjectId = typeof sourceAssignment.projectId === 'string' && sourceAssignment.projectId
    ? sourceAssignment.projectId
    : '';
  const plan = planFor(sourceProjectId, sourceCwd);
  const targetCwd = rebasePath(sourceCwd) || plan.roots[0];
  const targetAssignment = clone(sourceAssignment);
  targetAssignment.projectKind = 'local';
  targetAssignment.projectId = plan.targetProjectId;
  targetAssignment.cwd = targetCwd;
  targetAssignment.pendingCoreUpdate = false;
  targetAssignments[row.targetId] = targetAssignment;

  const sourceHint = typeof sourceHints[row.sourceId] === 'string' && sourceHints[row.sourceId]
    ? sourceHints[row.sourceId]
    : sourceCwd;
  targetHints[row.targetId] = rebasePath(sourceHint) || targetCwd;
  plan.targetIds.push(row.targetId);
  plan.sourceToTarget[row.sourceId] = row.targetId;
  importedTargetIds[row.targetId] = true;
  layoutRows.push(`${row.targetId}\t${targetCwd}`);
}

targetState['projectless-thread-ids'] = targetProjectless.filter((id) => !importedTargetIds[id]);

for (const plan of planOrder) {
  const sourceOrder = isObject(sourceOrders[plan.sourceProjectId]) && Array.isArray(sourceOrders[plan.sourceProjectId].threadIds)
    ? sourceOrders[plan.sourceProjectId].threadIds
    : [];
  const orderedIds = [];
  for (const sourceId of sourceOrder) {
    const targetId = plan.sourceToTarget[sourceId];
    if (targetId && !orderedIds.includes(targetId)) {
      orderedIds.push(targetId);
    }
  }
  for (const targetId of plan.targetIds) {
    if (!orderedIds.includes(targetId)) {
      orderedIds.push(targetId);
    }
  }
  targetOrders[plan.targetProjectId] = {threadIds: orderedIds};
}

const orderedPlanIds = [];
for (const sourceProjectId of sourceProjectOrder) {
  if (plans[sourceProjectId]) {
    orderedPlanIds.push(plans[sourceProjectId].targetProjectId);
  }
}
for (const plan of planOrder) {
  if (!orderedPlanIds.includes(plan.targetProjectId)) {
    orderedPlanIds.push(plan.targetProjectId);
  }
}
for (const projectId of orderedPlanIds) {
  const index = targetProjectOrder.indexOf(projectId);
  if (index >= 0) {
    targetProjectOrder.splice(index, 1);
  }
}
targetState['project-order'] = targetProjectOrder.concat(orderedPlanIds);

writeText(targetGlobalPath, `${JSON.stringify(targetState)}\n`);
writeText(outputLayoutPath, layoutRows.length > 0 ? `${layoutRows.join('\n')}\n` : '');
writeText(outputSummaryPath, [
  `projects\t${planOrder.length}`,
  `assigned_threads\t${layoutRows.length}`,
  `computer_name\t${sourceComputerName}`,
].join('\n') + '\n');
