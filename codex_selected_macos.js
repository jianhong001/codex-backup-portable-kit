#!/usr/bin/osascript -l JavaScript
ObjC.import('Foundation');

const app = Application.currentApplication();
app.includeStandardAdditions = true;
const fm = $.NSFileManager.defaultManager;
function env(key) {
  const value = $.NSProcessInfo.processInfo.environment.objectForKey($(key));
  return value ? ObjC.unwrap(value) : '';
}
function fail(message) { throw new Error(message); }
function quote(value) { return "'" + String(value).replace(/'/g, "'\\''") + "'"; }
function sqlValue(value) { return "'" + String(value).replace(/'/g, "''") + "'"; }
function shell(command) { return app.doShellScript(command); }
function read(path) {
  const value = $.NSString.stringWithContentsOfFileEncodingError($(path), $.NSUTF8StringEncoding, null);
  if (!value) fail('无法读取 UTF-8 文件：' + path);
  return ObjC.unwrap(value);
}
function write(path, text) {
  if (!$(text).writeToFileAtomicallyEncodingError($(path), true, $.NSUTF8StringEncoding, null)) fail('无法写入：' + path);
}
function json(path) { return JSON.parse(read(path)); }
function exists(path) { return fm.fileExistsAtPath($(path)); }
function mkdir(path) {
  if (!fm.createDirectoryAtPathWithIntermediateDirectoriesAttributesError($(path), true, $.NSDictionary.dictionary, null)) fail('无法创建目录：' + path);
}
function dirname(path) { return path.slice(0, path.lastIndexOf('/')) || '/'; }
function basename(path) { return path.replace(/\/+$/, '').split('/').pop(); }
function within(path, root) { return path === root || path.startsWith(root + '/'); }
function safePath(path) {
  if (typeof path !== 'string' || !path.startsWith('/') || /[\x00-\x1f"\\]/.test(path) || path.split('/').some(p => p === '..' || p === '.')) fail('路径含有暂不支持的字符：' + path);
  return path.replace(/\/+$/, '') || '/';
}
function regular(path) {
  const attrs = fm.attributesOfItemAtPathError($(path), null);
  return attrs && ObjC.unwrap(attrs.objectForKey($.NSFileType)) === 'NSFileTypeRegular';
}
function physical(path) { return shell('/bin/realpath ' + quote(path)); }
function hash(path) { return shell('/usr/bin/shasum -a 256 -- ' + quote(path)).split(/\s+/)[0]; }
function key(value) { return shell('/usr/bin/printf %s ' + quote(value) + ' | /usr/bin/shasum -a 256').slice(0, 24); }
function query(db, sql) { return JSON.parse(shell('/usr/bin/sqlite3 -readonly -json ' + quote(db) + ' ' + quote(sql)) || '[]'); }
function execute(db, sql) { shell('/usr/bin/sqlite3 -bail ' + quote(db) + ' ' + quote(sql)); }
function columns(db, table) { return query(db, 'PRAGMA table_info(' + sqlValue(table) + ')').map(r => r.name); }
function tables(db) { return query(db, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").map(r => r.name); }
function object(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function loadCatalog(home, db) {
  const state = exists(home + '/.codex-global-state.json') ? json(home + '/.codex-global-state.json') : {};
  const local = object(state['local-projects']) ? state['local-projects'] : {};
  const projects = Object.keys(local).map(id => ({id, name: local[id].name || id, roots: local[id].rootPaths || []}));
  const coreProjects = tables(db).includes('projects') ? query(db, 'SELECT id,name FROM projects ORDER BY position') : [];
  for (const project of coreProjects) {
    const roots = query(db, 'SELECT path FROM project_roots WHERE project_id=' + sqlValue(project.id) + ' ORDER BY position').map(r => r.path);
    const legacy = projects.find(p => p.name === project.name && JSON.stringify(p.roots) === JSON.stringify(roots));
    if (legacy) legacy.coreId = project.id;
    else projects.push({id: project.id, coreId: project.id, name: project.name, roots});
  }
  const cols = columns(db, 'threads');
  const select = ['id','title','cwd','rollout_path','updated_at','archived'].concat(['name','project_id','history_mode'].filter(c => cols.includes(c)));
  const threads = query(db, 'SELECT ' + select.join(',') + ' FROM threads ORDER BY updated_at DESC');
  const assignments = state['thread-project-assignments'] || {};
  for (const thread of threads) {
    thread.title = thread.name || thread.title || thread.id;
    const assignment = assignments[thread.id] || {};
    let project = projects.find(p => p.id === assignment.projectId || (thread.project_id && (p.id === thread.project_id || p.coreId === thread.project_id)));
    if (!project) {
      const matches = projects.filter(p => p.roots.some(root => within(thread.cwd, root)));
      matches.sort((a,b) => Math.max(...b.roots.filter(r => within(thread.cwd,r)).map(r => r.length)) - Math.max(...a.roots.filter(r => within(thread.cwd,r)).map(r => r.length)));
      if (matches.length === 1 || (matches.length > 1 && JSON.stringify(matches[0].roots) !== JSON.stringify(matches[1].roots))) project = matches[0];
    }
    if (!project) {
      const id = 'folder-' + key(thread.cwd);
      project = projects.find(p => p.id === id);
      if (!project) {
        project = {id, name: basename(thread.cwd) || '未归类聊天', roots: [thread.cwd]};
        projects.push(project);
      }
    }
    thread.projectId = project.id;
  }
  for (const project of projects) project.threadCount = threads.filter(t => t.projectId === project.id).length;
  return {projects: projects.filter(p => p.threadCount > 0), threads};
}

const excludedDirs = new Set(['.git','.venv','venv','node_modules','__pycache__','.cache','.next','.nuxt','.turbo','.pytest_cache','.mypy_cache','.ruff_cache','.tox','target','DerivedData']);
function excluded(relative) {
  return relative.split('/').some(part => excludedDirs.has(part) || /^(?:\.env(?:\..*)?|auth\.json|config\.toml|\.npmrc|\.pypirc|\.netrc|\.git-credentials|id_rsa|id_ed25519|credentials(?:\..*)?|\.DS_Store)$/.test(part) || /\.(?:pem|key|p12|pfx|kdbx|sock|ipc)$/.test(part));
}
function selection(catalog, kind, id) {
  const threads = catalog.threads.filter(t => kind === 'thread' ? t.id === id : t.projectId === id);
  if (!threads.length) fail('没有找到所选聊天。请重新打开选择窗口。');
  if (threads.some(t => t.history_mode && t.history_mode !== 'legacy')) fail('所选聊天使用了暂不支持的历史格式，未导出。');
  const project = catalog.projects.find(p => p.id === threads[0].projectId);
  const candidates = project.roots.concat(threads.map(t => t.cwd)).map(safePath);
  const roots = [...new Set(candidates)].filter(r => !candidates.some(parent => parent !== r && within(r, parent)));
  return {kind, id, name: kind === 'thread' ? threads[0].title : project.name, project, threads, roots};
}
function validateRoot(root, home) {
  const userHome = env('HOME');
  if ([ '/', '/Users', userHome, userHome + '/Documents', userHome + '/Desktop', userHome + '/Downloads', home ].includes(root) || within(home, root)) fail('所选项目包含过大的系统或个人目录，已停止。请将项目指向专用子文件夹：' + root);
  if (!exists(root) || physical(root) !== root) fail('项目文件夹不存在或包含符号链接：' + root);
}

function prepare(home, db, stage, kind, id) {
  const selected = selection(loadCatalog(home, db), kind, id);
  selected.roots.forEach(root => validateRoot(root, home));
  if (selected.roots.some(root => within(stage,root))) fail('导出位置不能放在所选项目里面。');
  const virtualRoot = '/__codex_selected_projects__';
  const rootMap = selected.roots.map(root => ({source: root, relative: 'root-' + key(root), virtual: virtualRoot + '/root-' + key(root)}));
  const mapPath = path => {
    const mapping = rootMap.find(r => within(path, r.source));
    if (!mapping) fail('聊天工作目录没有对应项目文件：' + path);
    return mapping.virtual + path.slice(mapping.source.length);
  };
  const files = [];
  const skipped = [];
  function add(source, entry) {
    safePath(source);
    if (!regular(source) || physical(source) !== source) fail('文件不存在或为符号链接：' + source);
    const attrs = fm.attributesOfItemAtPathError($(source), null);
    files.push({source, path: entry, size: Number(ObjC.unwrap(attrs.objectForKey($.NSFileSize)))});
  }
  for (const thread of selected.threads) {
    if (!/^[0-9a-f-]{36}$/i.test(thread.id)) fail('不支持的聊天 ID');
    const path = safePath(thread.rollout_path);
    if (!within(path, home + '/sessions') && !within(path, home + '/archived_sessions')) fail('聊天文件不在本机历史目录：' + path);
    const header = JSON.parse(shell('/usr/bin/head -n 1 ' + quote(path)));
    if (header.type !== 'session_meta' || header.payload.id !== thread.id) fail('聊天索引与文件不一致：' + thread.title);
    add(path, 'codex-home/' + (thread.archived ? 'archived_sessions/' : 'sessions/') + 'selected/' + thread.id + '.jsonl');
  }
  for (const root of rootMap) {
    mkdir(stage + '/projects/' + root.relative);
    const enumerator = fm.enumeratorAtPath($(root.source));
    let item;
    while ((item = ObjC.unwrap(enumerator.nextObject))) {
      const relative = item;
      if (excluded(relative)) { enumerator.skipDescendants; continue; }
      safePath(root.source + '/' + relative);
      const attrs = fm.attributesOfItemAtPathError($(root.source + '/' + relative), null);
      if (!attrs) fail('无法读取项目文件：' + relative);
      const type = ObjC.unwrap(attrs.objectForKey($.NSFileType));
      if (type === 'NSFileTypeDirectory') continue;
      if (type !== 'NSFileTypeRegular') { skipped.push(root.source + '/' + relative); continue; }
      add(root.source + '/' + relative, 'projects/' + root.relative + '/' + relative);
    }
  }
  const ids = selected.threads.map(t => sqlValue(t.id)).join(',');
  const dbTables = tables(db);
  if (dbTables.includes('thread_artifacts') && query(db, 'SELECT count(*) AS n FROM thread_artifacts WHERE thread_id IN (' + ids + ')')[0].n > 0) fail('所选聊天包含新版附件索引，当前尚不支持无损迁移，未导出。');
  const sql = ['PRAGMA foreign_keys=OFF;', 'PRAGMA secure_delete=ON;', 'BEGIN;', 'DELETE FROM threads WHERE id NOT IN (' + ids + ');'];
  for (const table of dbTables) {
    if (!/^[a-zA-Z_][a-zA-Z0-9_]*$/.test(table)) fail('不支持的数据库表名');
    if (table === 'threads') continue;
    if (table === 'thread_dynamic_tools') sql.push('DELETE FROM "' + table + '" WHERE thread_id NOT IN (' + ids + ');');
    else if (table === 'thread_spawn_edges') sql.push('DELETE FROM thread_spawn_edges WHERE parent_thread_id NOT IN (' + ids + ') OR child_thread_id NOT IN (' + ids + ');');
    else if (table === 'thread_sections' && columns(db,'threads').includes('thread_section_id')) sql.push('DELETE FROM thread_sections WHERE id NOT IN (SELECT thread_section_id FROM threads WHERE thread_section_id IS NOT NULL);');
    else {
      const linked = columns(db,table).some(c => ['thread_id','parent_thread_id','child_thread_id'].includes(c));
      if (linked && table !== 'thread_artifacts' && query(db, 'SELECT count(*) AS n FROM "' + table + '"')[0].n > 0) fail('存在未支持的聊天关联数据：' + table);
      sql.push('DELETE FROM "' + table + '";');
    }
  }
  const threadCols = columns(db, 'threads');
  for (const thread of selected.threads) sql.push('UPDATE threads SET cwd=' + sqlValue(mapPath(thread.cwd)) + (threadCols.includes('project_id') ? ',project_id=NULL' : '') + (threadCols.includes('git_origin_url') ? ',git_origin_url=NULL' : '') + ' WHERE id=' + sqlValue(thread.id) + ';');
  sql.push('COMMIT;', 'VACUUM;');
  execute(db, sql.join('\n'));
  const state = {'local-projects': {}, 'thread-project-assignments': {}, 'project-order': [selected.project.id]};
  state['local-projects'][selected.project.id] = {id: selected.project.id, name: selected.project.name, rootPaths: rootMap.map(r => r.virtual)};
  for (const thread of selected.threads) state['thread-project-assignments'][thread.id] = {projectId: selected.project.id, projectKind: 'local', cwd: mapPath(thread.cwd)};
  mkdir(stage + '/codex-home');
  write(stage + '/codex-home/.codex-global-state.json', JSON.stringify(state) + '\n');
  write(stage + '/backup-metadata/selection.json', JSON.stringify({format: 'codex-selected-v1', kind, id, name: selected.name, threadIds: selected.threads.map(t => t.id), roots: rootMap, skipped, scopeKey: key(kind + ':' + id)}) + '\n');
  write(stage + '/backup-metadata/未包含的文件.txt', '未包含全局 memory、skills、账号配置、Git 历史及项目依赖。\n项目目录以外的附件路径不会自动抓取；聊天内嵌图片仍保留。\n未跟随的链接或特殊文件：\n' + skipped.join('\n') + '\n');
  write(env('CODEX_SELECTED_FILE_PLAN'), JSON.stringify(files) + '\n');
  return JSON.stringify({name: selected.name, threads: selected.threads.length, files: files.length, bytes: files.reduce((n,f) => n+f.size,0), skipped: skipped.length, scopeKey: key(kind + ':' + id)});
}

function stageFiles(stage, planPath) {
  const files = json(planPath);
  for (const file of files) {
    const target = stage + '/' + file.path;
    mkdir(dirname(target));
    if (file.path.startsWith('codex-home/')) shell('/bin/cp -p ' + quote(file.source) + ' ' + quote(target));
    else if (!fm.createSymbolicLinkAtPathWithDestinationPathError($(target), $(file.source), null)) fail('无法暂存：' + file.source);
  }
  const entries = [];
  const enumerator = fm.enumeratorAtPath($(stage));
  let item;
  while ((item = ObjC.unwrap(enumerator.nextObject))) {
    const relative = item;
    const path = stage + '/' + relative;
    const attrs = fm.attributesOfItemAtPathError($(path), null);
    if (ObjC.unwrap(attrs.objectForKey($.NSFileType)) === 'NSFileTypeDirectory') continue;
    entries.push({path: relative, sha256: hash(path)});
  }
  write(stage + '/backup-metadata/FILES.json', JSON.stringify({format:'codex-selected-files-v1', files: entries}) + '\n');
}

function verify(stage) {
  const manifest = json(stage + '/backup-metadata/FILES.json');
  if (manifest.format !== 'codex-selected-files-v1' || !Array.isArray(manifest.files) || manifest.files.length > 250000) fail('文件校验清单无效');
  const expected = new Set(['backup-metadata/FILES.json']);
  for (const entry of manifest.files) {
    if (!object(entry) || typeof entry.path !== 'string' || !/^(codex-home|projects|backup-metadata)\//.test(entry.path) || entry.path.split('/').some(p => !p || p === '.' || p === '..') || /[\x00-\x1f\\]/.test(entry.path) || expected.has(entry.path) || !/^[0-9a-f]{64}$/.test(entry.sha256)) fail('不安全或重复的文件校验项');
    if (!regular(stage + '/' + entry.path) || physical(stage + '/' + entry.path) !== stage + '/' + entry.path || hash(stage + '/' + entry.path) !== entry.sha256) fail('文件损坏或被修改：' + entry.path);
    expected.add(entry.path);
  }
  const enumerator = fm.enumeratorAtPath($(stage));
  let item;
  while ((item = ObjC.unwrap(enumerator.nextObject))) {
    const relative = item;
    const attrs = fm.attributesOfItemAtPathError($(stage + '/' + relative), null);
    const type = ObjC.unwrap(attrs.objectForKey($.NSFileType));
    if (type === 'NSFileTypeDirectory') continue;
    if (type !== 'NSFileTypeRegular' || !expected.has(relative)) fail('存在未校验的文件：' + relative);
  }
  const selected = json(stage + '/backup-metadata/selection.json');
  if (selected.format !== 'codex-selected-v1' || !Array.isArray(selected.threadIds) || !selected.threadIds.length) fail('选择清单无效');
  if (!Array.isArray(selected.roots) || !selected.roots.length || selected.roots.length > 128) fail('项目根目录清单无效');
  for (const root of selected.roots) {
    safePath(root.source);
    if (!/^root-[a-f0-9]{24}$/.test(root.relative) || root.virtual !== '/__codex_selected_projects__/' + root.relative) fail('无效的项目路径映射');
  }
  const db = stage + '/backup-metadata/sqlite-consistent-snapshots/state_5.sqlite';
  const ids = query(db, 'SELECT id FROM threads ORDER BY id').map(r=>r.id);
  if (JSON.stringify(ids) !== JSON.stringify(selected.threadIds.slice().sort())) fail('聊天选择范围与索引不一致');
  return 'ok';
}

function verifyArchive(archive) {
  const manifest = JSON.parse(shell('/usr/bin/unzip -p ' + quote(archive) + ' backup-metadata/FILES.json'));
  if (manifest.format !== 'codex-selected-files-v1' || !Array.isArray(manifest.files)) fail('文件校验清单无效');
  const expected = new Set(['backup-metadata/FILES.json']);
  for (const file of manifest.files) {
    if (typeof file.path !== 'string' || /[\x00-\x1f\\]/.test(file.path) || file.path.split('/').some(p=>!p || p==='.' || p==='..') || expected.has(file.path) || !/^[a-f0-9]{64}$/.test(file.sha256)) fail('校验清单包含不安全路径');
    expected.add(file.path);
    const pattern = file.path.replace(/[\[*?]/g, c => '[' + c + ']');
    const actual = shell('/usr/bin/unzip -p ' + quote(archive) + ' ' + quote(pattern) + ' | /usr/bin/shasum -a 256').split(/\s+/)[0];
    if (actual !== file.sha256) fail('压缩期间文件发生变化：' + file.path);
  }
  const seen = new Set();
  const paths = shell('/usr/bin/bsdtar -tf ' + quote(archive)).split(/[\r\n]+/).filter(Boolean);
  for (const path of paths) {
    if (seen.has(path)) fail('ZIP 中存在重复路径');
    seen.add(path);
    if (!path.endsWith('/') && !expected.has(path)) fail('ZIP 中存在未校验文件');
  }
  for (const path of expected) if (!seen.has(path)) fail('ZIP 中缺少文件：' + path);
  return 'ok';
}

function linkProjects(db, globalPath, importMap) {
  if (!tables(db).includes('projects')) return;
  const state = json(globalPath);
  const rows = read(importMap).trim().split('\n').filter(Boolean).map(line=>line.split('\t')).filter(row=>row[4]==='0');
  const ids = new Set();
  const sql = ['PRAGMA foreign_keys=ON;', 'BEGIN;'];
  for (const row of rows) {
    const assignment = state['thread-project-assignments'][row[0]];
    const project = state['local-projects'][assignment.projectId];
    if (!ids.has(project.id)) {
      const existing = query(db, 'SELECT name FROM projects WHERE id=' + sqlValue(project.id));
      if (existing.length) {
        const roots = query(db, 'SELECT path FROM project_roots WHERE project_id=' + sqlValue(project.id) + ' ORDER BY position').map(r=>r.path);
        if (existing[0].name !== project.name || JSON.stringify(roots) !== JSON.stringify(project.rootPaths)) fail('项目 ID 冲突，未导入。');
      } else {
        sql.push('INSERT INTO projects(id,name,metadata,position,created_at_ms,updated_at_ms) VALUES (' + sqlValue(project.id) + ',' + sqlValue(project.name) + ",'{}',(SELECT COALESCE(MAX(position),-1)+1 FROM projects)," + Date.now() + ',' + Date.now() + ');');
        project.rootPaths.forEach((root,i) => sql.push('INSERT INTO project_roots(project_id,position,path) VALUES (' + sqlValue(project.id) + ',' + i + ',' + sqlValue(root) + ');'));
      }
      ids.add(project.id);
    }
    sql.push('UPDATE threads SET project_id=' + sqlValue(project.id) + ' WHERE id=' + sqlValue(row[0]) + ';');
  }
  sql.push('COMMIT;');
  execute(db, sql.join('\n'));
}

function rewriteSessions(planPath, selectionPath, importRoot) {
  const selected = json(selectionPath);
  function mapPath(path) {
    if (typeof path !== 'string') return path;
    for (const root of selected.roots) {
      if (within(path, root.source)) return importRoot + '/' + root.relative + path.slice(root.source.length);
      if (within(path, root.virtual)) return importRoot + '/' + root.relative + path.slice(root.virtual.length);
    }
    return path;
  }
  const plans = read(planPath).split('\n').filter(Boolean).map(line => line.split('\t'));
  const newline = $('\n').dataUsingEncoding($.NSUTF8StringEncoding);
  for (const row of plans) {
    const path = row[0];
    const input = $.NSFileHandle.fileHandleForReadingAtPath($(path));
    const outputPath = path + '.rewritten';
    fm.createFileAtPathContentsAttributes($(outputPath), $.NSData.data, $.NSDictionary.dictionary);
    const output = $.NSFileHandle.fileHandleForWritingAtPath($(outputPath));
    const buffer = $.NSMutableData.data;
    function process(data) {
      const decoded = $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding);
      if (!decoded) fail('聊天文件不是有效 UTF-8');
      const lines = ObjC.unwrap(decoded).split('\n');
      for (let line of lines) {
        if (!line.trim()) continue;
        const item = JSON.parse(line);
        if ((item.type === 'session_meta' || item.type === 'turn_context') && object(item.payload)) {
          if (typeof item.payload.cwd === 'string') item.payload.cwd = mapPath(item.payload.cwd);
          line = JSON.stringify(item);
        }
        output.writeData($(line + '\n').dataUsingEncoding($.NSUTF8StringEncoding));
      }
    }
    try {
      while (true) {
        const data = input.readDataOfLength(65536);
        if (Number(data.length) === 0) break;
        buffer.appendData(data);
        if (Number(buffer.length) > 67108864) fail('单行聊天记录过大，已停止而不修改目标资料。');
        const range = buffer.rangeOfDataOptionsRange(newline, 2, $.NSMakeRange(0,Number(buffer.length)));
        if (Number(range.location) < Number(buffer.length)) {
          const length = Number(range.location) + 1;
          process(buffer.subdataWithRange($.NSMakeRange(0,length)));
          const rest = buffer.subdataWithRange($.NSMakeRange(length,Number(buffer.length)-length));
          buffer.setData(rest);
        }
      }
      if (Number(buffer.length)) process(buffer);
      output.synchronizeFile;
    } finally {
      input.closeFile;
      output.closeFile;
    }
    shell('/bin/mv ' + quote(outputPath) + ' ' + quote(path));
  }
}

function choose(catalog, requestedKind) {
  let kind = requestedKind;
  if (!['thread','project'].includes(kind)) {
    const type = app.chooseFromList(['整个项目（全部聊天和文件）','一条聊天（含所属项目文件）'], {withTitle:'选择要带走的内容', withPrompt:'导出范围', defaultItems:['整个项目（全部聊天和文件）']});
    if (!type) return '';
    kind = String(type[0]).startsWith('整个') ? 'project' : 'thread';
  }
  const term = app.displayDialog('输入名称关键词，留空显示全部。', {defaultAnswer:'', buttons:['取消','查找'], defaultButton:'查找', cancelButton:'取消'}).textReturned.trim().toLowerCase();
  const items = (kind === 'project' ? catalog.projects : catalog.threads).filter(x => (kind === 'project' ? x.name : x.title).toLowerCase().includes(term));
  if (!items.length) fail('没有找到匹配项。');
  const labels = items.map((x,i) => (i+1) + '. ' + (kind === 'project' ? x.name + ' · ' + x.threadCount + ' 条聊天' : x.title + (x.archived ? '（已归档）' : '')) + ' [' + x.id.slice(-8) + ']');
  const result = app.chooseFromList(labels, {withTitle:'选择导出', withPrompt:'仅导出选中项及其项目文件', multipleSelectionsAllowed:false});
  if (!result) return '';
  return kind + '\t' + items[labels.indexOf(result[0])].id;
}

function runMain(argv) {
  const mode = argv[0];
  const home = safePath(env('CODEX_HOME') || env('HOME') + '/.codex');
  const db = env('CODEX_SELECTED_DB') || home + '/state_5.sqlite';
  const stage = env('CODEX_SELECTED_STAGE');
  if (mode === 'catalog' || mode === 'choose') {
    const catalog = loadCatalog(home, db);
    return mode === 'choose' ? choose(catalog,argv[1]) : JSON.stringify(catalog);
  }
  if (mode === 'prepare') return prepare(home, db, stage, argv[1], argv[2]);
  if (mode === 'stage') return stageFiles(stage, env('CODEX_SELECTED_FILE_PLAN'));
  if (mode === 'verify') return verify(physical(stage));
  if (mode === 'verify-archive') return verifyArchive(argv[1]);
  if (mode === 'link-projects') return linkProjects(argv[1],argv[2],argv[3]);
  if (mode === 'rewrite-sessions') return rewriteSessions(argv[1],argv[2],argv[3]);
  if (mode === 'confirm') {
    const info = json(argv[1]);
    const selected = json(stage + '/backup-metadata/selection.json');
    app.displayDialog(info.name + '\n' + info.threads + ' 条聊天，' + info.files + ' 个文件\n\n项目文件夹：\n' + selected.roots.map(r=>r.source).join('\n') + '\n\n这些文件夹里的文件都会带走（账号和依赖等除外）。', {withTitle:'确认导出范围',buttons:['取消','导出'],defaultButton:'导出',cancelButton:'取消'});
    return 'ok';
  }
  fail('未知操作：' + mode);
}
function run(argv) { return runMain(argv); }
