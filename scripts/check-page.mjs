#!/usr/bin/env node
// Проверяет страницу agentflow.html в браузере без окна по DevTools Protocol.
// Запуск: node scripts/check-page.mjs [путь к agentflow.html]
// Коды выхода: 0 все проверки зелёные, 1 есть красные, 2 браузер не найден или не запустился.
// Зависимостей нет: нужны Node.js и Chrome или Chromium. Путь к браузеру: CHROME_PATH или стандартные места.
import { spawn } from 'node:child_process';
import { existsSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const DEFAULT_PAGE = join(ROOT, 'agentflow.html');
const WIDTHS = [375, 768, 1280];
const SCREEN_HEIGHT = 900;
const CMD_TIMEOUT_MS = 15000;
const LAUNCH_TIMEOUT_MS = 20000;
const LOAD_TIMEOUT_MS = 15000;
const MAX_STEPS = 200;
const CHROME_CANDIDATES = [
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/Applications/Chromium.app/Contents/MacOS/Chromium',
  '/usr/bin/google-chrome',
  '/usr/bin/google-chrome-stable',
  '/usr/bin/chromium',
  '/usr/bin/chromium-browser',
  '/snap/bin/chromium',
];

// Сборщик событий страницы. Обнуляется перед каждым размером экрана; консоль и сеть проверяются по нему.
const seen = { problems: [], requests: [] };

// Ждёт, пока страница закончит ход плеера (ручной переход или проигрывание).
function waitIdle(ctx) {
  return ctx.eval(`new Promise(done => {
    let n = 0;
    const tick = () => {
      if (!window.FlowRoutes.isBusy()) return done(true);
      if (++n > 200) return done(false);
      setTimeout(tick, 25);
    };
    tick();
  })`).then((ok) => {
    if (!ok) throw new Error('анимация плеера не закончилась за 5 с');
  });
}

const CHECKS = [];

// region: checks-head
CHECKS.push({
  name: 'в шапке нет ряда участников, колонка дорожек показывает шесть агентов по FLOW.lanes',
  run: async (ctx) => {
    const left = await ctx.eval("document.querySelectorAll('#head-team, .head-agent').length");
    if (left !== 0) throw new Error(`в шапке осталось ${left} элементов ряда участников`);
    const rows = await ctx.eval("Array.from(document.querySelectorAll('.lane-agent')).map(r => { const n = r.querySelector('.lane-name'); return n ? n.textContent.trim() : ''; })");
    const expected = await ctx.eval('FLOW.lanes.map(l => l.name)');
    if (rows.length !== 6) throw new Error(`строк .lane-agent ${rows.length}, ожидалось 6`);
    if (JSON.stringify(rows) !== JSON.stringify(expected)) {
      throw new Error(`имена дорожек ${JSON.stringify(rows)}, ожидались ${JSON.stringify(expected)} в порядке FLOW.lanes`);
    }
  },
});
// end region

// region: checks-base
CHECKS.push({
  name: 'у страницы нет горизонтальной прокрутки',
  run: async (ctx) => {
    const width = await ctx.eval('document.documentElement.scrollWidth');
    if (width > ctx.width) {
      throw new Error(`ширина содержимого ${width} px больше экрана ${ctx.width} px`);
    }
  },
});

CHECKS.push({
  name: 'каждый сценарий из #scenario проходится кнопкой «Шаг» до конца без ошибок',
  run: async (ctx) => {
    const names = await ctx.eval("Array.from(document.querySelectorAll('#scenario option')).map(o => o.value)");
    if (names.length === 0) throw new Error('в #scenario нет сценариев');
    for (const value of names) {
      const before = seen.problems.length;
      await ctx.eval(`(() => {
        const s = document.getElementById('scenario');
        s.value = ${JSON.stringify(value)};
        s.dispatchEvent(new Event('change'));
      })()`);
      let steps = 0;
      for (;;) {
        await waitIdle(ctx);
        const canStep = await ctx.eval("!document.getElementById('btn-step').disabled");
        if (!canStep) break;
        if (++steps > MAX_STEPS) throw new Error(`сценарий «${value}» не доходит до конца за ${MAX_STEPS} шагов`);
        await ctx.eval("document.getElementById('btn-step').click()");
      }
      if (steps === 0) throw new Error(`сценарий «${value}»: кнопка «Шаг» не работает`);
      const status = await ctx.eval("document.getElementById('player-status').textContent.trim()");
      if (!status) throw new Error(`сценарий «${value}»: #player-status пуст в конце`);
      if (seen.problems.length > before) {
        throw new Error(`сценарий «${value}»: ${seen.problems.slice(before).join('; ')}`);
      }
    }
  },
});

CHECKS.push({
  name: 'клик по узлу графа заполняет боковую панель выбранным шагом',
  run: async (ctx) => {
    const nodeId = await ctx.eval(`(() => {
      const cur = document.querySelector('.node-g.is-selected');
      const other = Array.from(document.querySelectorAll('.node-g')).find(g => g !== cur);
      return other ? other.dataset.id : null;
    })()`);
    if (!nodeId) throw new Error('в графе нет узла для клика');
    await ctx.eval(`(() => {
      const g = Array.from(document.querySelectorAll('.node-g')).find(x => x.dataset.id === ${JSON.stringify(nodeId)});
      g.dispatchEvent(new MouseEvent('click', { bubbles: true }));
    })()`);
    const title = await ctx.eval("document.querySelector('#panel .panel-title') ? document.querySelector('#panel .panel-title').textContent.trim() : ''");
    const expected = await ctx.eval(`(FLOW.nodes.find(n => n.id === ${JSON.stringify(nodeId)}) || {}).name`);
    if (!expected || title !== expected) {
      throw new Error(`панель показывает «${title}», ожидался шаг «${expected}»`);
    }
  },
});

CHECKS.push({
  name: 'кнопка «Свернуть» меняет aria-expanded у #btn-hide и #btn-show и возвращает обратно',
  run: async (ctx) => {
    const expanded = "[document.getElementById('btn-hide').getAttribute('aria-expanded'), document.getElementById('btn-show').getAttribute('aria-expanded')]";
    await ctx.eval("document.getElementById('btn-hide').click()");
    const collapsed = await ctx.eval(expanded);
    if (collapsed[0] !== 'false' || collapsed[1] !== 'false') {
      throw new Error(`после «Свернуть» aria-expanded ${JSON.stringify(collapsed)}, ожидались false`);
    }
    await ctx.eval("document.getElementById('btn-show').click()");
    const restored = await ctx.eval(expanded);
    if (restored[0] !== 'true' || restored[1] !== 'true') {
      throw new Error(`после «Панель» aria-expanded ${JSON.stringify(restored)}, ожидались true`);
    }
  },
});

CHECKS.push({
  name: 'в консоли нет ошибок и необработанных исключений',
  run: async () => {
    if (seen.problems.length > 0) throw new Error(seen.problems.join('; '));
  },
});

CHECKS.push({
  name: 'нет запросов, кроме самого файла страницы',
  run: async () => {
    if (seen.requests.length > 0) throw new Error(`лишние запросы: ${seen.requests.join(', ')}`);
  },
});
// end region

// region: checks-legend
CHECKS.push({
  name: 'легенда это один закрытый details.legend с summary «Обозначения» и четырьмя .legend-item',
  run: async (ctx) => {
    const count = await ctx.eval("document.querySelectorAll('details.legend').length");
    if (count !== 1) throw new Error(`details.legend на странице: ${count}, ожидался один`);
    const state = await ctx.eval(`(() => {
      const d = document.querySelector('details.legend');
      const s = d.querySelector(':scope > summary');
      return {
        open: d.hasAttribute('open'),
        summary: s ? s.textContent.trim() : null,
        items: d.querySelectorAll('.legend-item').length,
      };
    })()`);
    if (state.open) throw new Error('легенда открыта при загрузке, ожидалась закрытой');
    if (state.summary !== 'Обозначения') throw new Error(`summary легенды «${state.summary}», ожидалось «Обозначения»`);
    if (state.items !== 4) throw new Error(`.legend-item в легенде: ${state.items}, ожидалось 4`);
  },
});

CHECKS.push({
  name: 'клик по summary легенды раскрывает и закрывает её',
  run: async (ctx) => {
    const isOpen = "document.querySelector('details.legend').hasAttribute('open')";
    await ctx.eval("document.querySelector('details.legend > summary').click()");
    if (!(await ctx.eval(isOpen))) throw new Error('после клика по summary легенда не открылась');
    await ctx.eval("document.querySelector('details.legend > summary').click()");
    if (await ctx.eval(isOpen)) throw new Error('после второго клика по summary легенда не закрылась');
  },
});
// end region

// region: runner
class Cdp {
  constructor(url) {
    this.nextId = 1;
    this.pending = new Map();
    this.handlers = [];
    this.ws = new WebSocket(url);
    this.ws.addEventListener('message', (ev) => this.#dispatch(JSON.parse(ev.data)));
  }

  open() {
    return new Promise((resolveOpen, reject) => {
      this.ws.addEventListener('open', () => resolveOpen(), { once: true });
      this.ws.addEventListener('error', () => reject(new Error('нет связи с браузером по DevTools')), { once: true });
    });
  }

  send(method, params = {}, sessionId) {
    const id = this.nextId++;
    return new Promise((resolveSend, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`браузер не ответил на ${method} за ${CMD_TIMEOUT_MS / 1000} с`));
      }, CMD_TIMEOUT_MS);
      this.pending.set(id, {
        resolve: (value) => { clearTimeout(timer); resolveSend(value); },
        reject: (error) => { clearTimeout(timer); reject(error); },
      });
      this.ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
    });
  }

  on(sessionId, method, fn) {
    this.handlers.push({ sessionId, method, fn });
  }

  once(sessionId, method, timeoutMs) {
    return new Promise((resolveOnce, reject) => {
      const timer = setTimeout(() => reject(new Error(`нет события ${method} за ${timeoutMs / 1000} с`)), timeoutMs);
      this.on(sessionId, method, () => { clearTimeout(timer); resolveOnce(); });
    });
  }

  #dispatch(msg) {
    if (msg.id !== undefined) {
      const p = this.pending.get(msg.id);
      if (!p) return;
      this.pending.delete(msg.id);
      if (msg.error) p.reject(new Error(msg.error.message));
      else p.resolve(msg.result);
      return;
    }
    for (const h of this.handlers) {
      if (h.method === msg.method && h.sessionId === msg.sessionId) h.fn(msg.params);
    }
  }

  close() {
    this.ws.close();
  }
}

function findBrowser() {
  const fromEnv = process.env.CHROME_PATH;
  if (fromEnv) {
    return existsSync(fromEnv)
      ? { path: fromEnv }
      : { error: `CHROME_PATH указывает на несуществующий файл: ${fromEnv}` };
  }
  const found = CHROME_CANDIDATES.find((p) => existsSync(p));
  return found
    ? { path: found }
    : { error: `браузер не найден: задайте CHROME_PATH или установите Chrome или Chromium. Проверены: ${CHROME_CANDIDATES.join(', ')}` };
}

function launchBrowser(path) {
  return new Promise((resolveLaunch, reject) => {
    const profile = mkdtempSync(join(tmpdir(), 'check-page-'));
    const child = spawn(path, [
      '--headless=new',
      '--disable-gpu',
      '--no-first-run',
      '--no-default-browser-check',
      '--remote-debugging-port=0',
      '--remote-allow-origins=*',
      `--user-data-dir=${profile}`,
      'about:blank',
    ], { stdio: ['ignore', 'ignore', 'pipe'] });

    let stderr = '';
    const timer = setTimeout(() => {
      child.kill();
      reject(new Error(`браузер ${path} не выдал адрес DevTools за ${LAUNCH_TIMEOUT_MS / 1000} с`));
    }, LAUNCH_TIMEOUT_MS);
    child.on('error', (e) => {
      clearTimeout(timer);
      reject(new Error(`не удалось запустить ${path}: ${e.message}`));
    });
    child.on('exit', (code) => {
      clearTimeout(timer);
      reject(new Error(`браузер ${path} завершился при запуске, код ${code}`));
    });
    child.stderr.on('data', (chunk) => {
      stderr += chunk;
      const m = stderr.match(/DevTools listening on (ws:\/\/\S+)/);
      if (m) {
        clearTimeout(timer);
        resolveLaunch({ child, profile, url: m[1] });
      }
    });
  });
}

function stopBrowser({ child, profile }) {
  return new Promise((resolveStop) => {
    const finish = () => {
      rmSync(profile, { recursive: true, force: true });
      resolveStop();
    };
    if (child.exitCode !== null) return finish();
    const killTimer = setTimeout(() => child.kill('SIGKILL'), 3000);
    child.once('exit', () => {
      clearTimeout(killTimer);
      finish();
    });
    child.kill();
  });
}

async function evaluate(cdp, sessionId, expression) {
  const r = await cdp.send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }, sessionId);
  if (r.exceptionDetails) {
    const details = r.exceptionDetails.exception?.description ?? r.exceptionDetails.text;
    throw new Error(String(details).split('\n')[0]);
  }
  return r.result.value;
}

// Один размер экрана: новая вкладка, страница грузится заново, потом все проверки подряд на этой странице.
async function runWidth(cdp, width, pageUrl) {
  const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
  const results = [];
  try {
    await cdp.send('Page.enable', {}, sessionId);
    await cdp.send('Runtime.enable', {}, sessionId);
    await cdp.send('Log.enable', {}, sessionId);
    await cdp.send('Network.enable', {}, sessionId);
    await cdp.send('Emulation.setDeviceMetricsOverride', {
      width,
      height: SCREEN_HEIGHT,
      deviceScaleFactor: 1,
      mobile: false,
    }, sessionId);

    seen.problems = [];
    seen.requests = [];
    cdp.on(sessionId, 'Runtime.consoleAPICalled', (p) => {
      if (p.type !== 'error' && p.type !== 'assert') return;
      seen.problems.push(`console.${p.type}: ${p.args.map((a) => a.value ?? a.description ?? a.type).join(' ')}`);
    });
    cdp.on(sessionId, 'Runtime.exceptionThrown', (p) => {
      const d = p.exceptionDetails;
      seen.problems.push(`необработанное исключение: ${d.exception?.description ?? d.text}`.split('\n')[0]);
    });
    cdp.on(sessionId, 'Log.entryAdded', (p) => {
      if (p.entry.level === 'error') seen.problems.push(`ошибка браузера: ${p.entry.text}${p.entry.url ? ` ${p.entry.url}` : ''}`);
    });
    cdp.on(sessionId, 'Network.requestWillBeSent', (p) => {
      const url = p.request.url;
      if (url.startsWith('data:')) return;
      if (url.split('#')[0] !== pageUrl) seen.requests.push(url);
    });

    const loaded = cdp.once(sessionId, 'Page.loadEventFired', LOAD_TIMEOUT_MS);
    await cdp.send('Page.navigate', { url: pageUrl }, sessionId);
    await loaded;
  } catch (e) {
    for (const check of CHECKS) results.push({ width, name: check.name, error: `страница не загрузилась: ${e.message}` });
    await cdp.send('Target.closeTarget', { targetId }).catch(() => {});
    return results;
  }

  const ctx = {
    width,
    eval: (expression) => evaluate(cdp, sessionId, expression),
  };
  for (const check of CHECKS) {
    try {
      await check.run(ctx);
      results.push({ width, name: check.name });
    } catch (e) {
      results.push({ width, name: check.name, error: e.message });
    }
  }
  await cdp.send('Target.closeTarget', { targetId }).catch(() => {});
  return results;
}

async function main() {
  const pagePath = resolve(process.argv[2] ?? DEFAULT_PAGE);
  if (!existsSync(pagePath)) {
    console.error(`Страница не найдена: ${pagePath}`);
    return 1;
  }

  const found = findBrowser();
  if (found.error) {
    console.error(found.error);
    return 2;
  }

  let browser;
  try {
    browser = await launchBrowser(found.path);
  } catch (e) {
    console.error(`Браузер не запустился: ${e.message}`);
    return 2;
  }

  const cdp = new Cdp(browser.url);
  const results = [];
  try {
    await cdp.open();
    const pageUrl = pathToFileURL(pagePath).href;
    for (const width of WIDTHS) {
      results.push(...await runWidth(cdp, width, pageUrl));
    }
  } catch (e) {
    console.error(`Браузер не ответил: ${e.message}`);
    return 2;
  } finally {
    cdp.close();
    await stopBrowser(browser);
  }

  let red = 0;
  for (const r of results) {
    if (r.error) {
      red += 1;
      console.log(`[${r.width} px] FAIL ${r.name}: ${r.error}`);
    } else {
      console.log(`[${r.width} px] ok   ${r.name}`);
    }
  }
  console.log(`\nПроверок: ${results.length}, красных: ${red}`);
  return red > 0 ? 1 : 0;
}

process.exit(await main());
// end region
