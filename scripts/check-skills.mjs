#!/usr/bin/env node
// Проверяет навыки: frontmatter, относительные ссылки и плейсхолдеры.
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { basename, dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const ALLOWED_PLACEHOLDERS = new Set(['NN', 'slug', 'feature-slug']);

const errors = [];
const fail = (file, message) => errors.push(`${relative(root, file)}: ${message}`);

function walk(dir) {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) return walk(path);
    return path.endsWith('.md') ? [path] : [];
  });
}

function checkFrontmatter(file, text) {
  const match = text.match(/^---\n([\s\S]*?)\n---\n/);
  if (!match) return fail(file, 'нет frontmatter');

  const fields = Object.fromEntries(
    match[1]
      .split('\n')
      .filter((line) => /^\w+:/.test(line))
      .map((line) => {
        const colon = line.indexOf(':');
        return [line.slice(0, colon), line.slice(colon + 1).trim()];
      }),
  );

  if (fields.name !== basename(dirname(file))) {
    fail(file, `name «${fields.name}» не совпадает с именем каталога`);
  }
  if (!fields.description) fail(file, 'нет description');
}

function checkLinks(file, text) {
  for (const [, target] of text.matchAll(/\]\(([^)\s]+)\)/g)) {
    if (/^(https?:|mailto:|#)/.test(target)) continue;
    const path = target.split('#')[0];
    if (!existsSync(resolve(dirname(file), path))) {
      fail(file, `битая ссылка ${target}`);
    }
  }
}

function checkPlaceholders(file, text) {
  for (const [, name] of text.matchAll(/<([A-Za-z][\w-]*)>/g)) {
    if (!ALLOWED_PLACEHOLDERS.has(name)) {
      fail(file, `неизвестный плейсхолдер <${name}>`);
    }
  }
}

const skillFiles = walk(join(root, 'skills'));
const docFiles = [...skillFiles, join(root, 'README.md'), join(root, 'AGENTS.md')];

for (const file of docFiles) {
  const text = readFileSync(file, 'utf8');
  if (basename(file) === 'SKILL.md') checkFrontmatter(file, text);
  checkLinks(file, text);
  checkPlaceholders(file, text);
}

if (errors.length > 0) {
  console.error(errors.join('\n'));
  console.error(`\nОшибок: ${errors.length}`);
  process.exit(1);
}
console.log(`OK: проверено файлов ${docFiles.length}`);
