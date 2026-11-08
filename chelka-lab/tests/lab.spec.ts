import { test, expect } from '@playwright/test';
import type { Page } from '@playwright/test';

const switchTo = async (page: Page, name: string) => {
  await page.getByRole('tab', { name: new RegExp(name) }).click();
  await expect(page.getByRole('tab', { name: new RegExp(name) })).toHaveAttribute('aria-selected', 'true');
};
const stable = async (page: Page) => { await page.waitForTimeout(750); };

test('Liquid: compact, hover, expand, transport, seek, volume and Escape', async ({ page }) => {
  const errors: string[] = []; page.on('pageerror', e => errors.push(e.message));
  await page.goto('/');
  const notch = page.getByTestId('liquid-notch');
  await expect(notch).toHaveAttribute('data-state', 'expanded');
  await page.getByRole('button', { name: 'Компактно', exact: true }).click();
  await expect(notch).toHaveAttribute('data-state', 'compact');
  await stable(page);
  const compactBox = await notch.boundingBox(); expect(compactBox?.width).toBeCloseTo(206, 0);
  await notch.hover();
  await expect(notch).toHaveAttribute('data-state', 'mini');
  await page.getByRole('button', { name: 'Увеличить плеер' }).click();
  await expect(notch).toHaveAttribute('data-state', 'expanded');
  await page.locator('.expanded-player').getByRole('button', { name: 'Пауза', exact: true }).click();
  await expect(page.getByRole('button', { name: 'Воспроизвести', exact: true })).toBeVisible();
  await expect(page.getByText('НА ПАУЗЕ', { exact: true })).toBeVisible();
  const paused = await page.getByRole('slider', { name: 'Прогресс трека' }).inputValue();
  await page.waitForTimeout(1100);
  await expect(page.getByRole('slider', { name: 'Прогресс трека' })).toHaveValue(paused);
  await page.getByRole('slider', { name: 'Прогресс трека' }).fill('150');
  await expect(page.getByRole('slider', { name: 'Прогресс трека' })).toHaveValue('150');
  await page.getByRole('slider', { name: 'Громкость' }).fill('32');
  await expect(page.getByRole('slider', { name: 'Громкость' })).toHaveValue('32');
  await page.getByRole('button', { name: 'Выключить звук' }).click();
  await expect(page.getByRole('slider', { name: 'Громкость' })).toHaveValue('0');
  await page.getByRole('button', { name: 'Следующий трек', exact: true }).first().click();
  await expect(page.getByRole('heading', { name: 'Slow Morning' })).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(notch).toHaveAttribute('data-state', 'compact');
  expect(errors).toEqual([]);
});

test('Liquid: rapid interruptions settle without clipping', async ({ page }) => {
  await page.goto('/');
  for (const size of ['Компактно', 'Раскрыто', 'Мини', 'Раскрыто', 'Компактно', 'Раскрыто']) {
    await page.getByRole('button', { name: size, exact: true }).click();
    await page.waitForTimeout(65);
  }
  await stable(page);
  const notch = await page.getByTestId('liquid-notch').boundingBox();
  const content = await page.locator('.expanded-player').boundingBox();
  expect(notch?.width).toBeCloseTo(420, 0); expect(notch?.height).toBeCloseTo(260, 0);
  expect(content!.y + content!.height).toBeLessThanOrEqual(notch!.y + notch!.height + 1);
  await page.screenshot({ path: 'artifacts/liquid-expanded.png', fullPage: true });
});

test('Orbit: event hierarchy, details, return, restore and dismiss', async ({ page }) => {
  await page.goto('/'); await switchTo(page, 'Orbit');
  await expect(page.getByTestId('orbit-event')).toHaveCount(2);
  await page.getByRole('button', { name: 'Раскрыть AirPods Pro' }).click();
  await expect(page.locator('.airpods-battery')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Раскрыть Codex' })).toHaveAttribute('aria-expanded', 'false');
  await page.getByRole('button', { name: 'Вернуть AirPods Pro в чёлку' }).click();
  await expect(page.getByTestId('orbit-event')).toHaveCount(1);
  await page.getByRole('button', { name: 'Вернуть события из чёлки (1)' }).click();
  await expect(page.getByTestId('orbit-event')).toHaveCount(2);
  await page.getByRole('button', { name: 'Скриншот', exact: true }).click();
  await expect(page.getByTestId('orbit-event')).toHaveCount(3);
  await expect(page.locator('.screenshot-preview')).toBeVisible();
  await page.getByRole('button', { name: 'Раскрыть Codex' }).click();
  await stable(page);
  const stack = await page.getByTestId('orbit-stack').boundingBox();
  const guidance = await page.locator('.scene-guidance').boundingBox();
  expect(stack!.y + stack!.height).toBeLessThan(guidance!.y - 5);
  const boxes = await page.getByTestId('orbit-event').evaluateAll(nodes => nodes.map(n => { const b = n.getBoundingClientRect(); return { top: b.top, bottom: b.bottom }; }));
  for (let i = 1; i < boxes.length; i++) expect(boxes[i].top).toBeGreaterThanOrEqual(boxes[i - 1].bottom + 6);
  expect(boxes.at(-1)!.bottom).toBeLessThanOrEqual(stack!.y + stack!.height - 4);
  await page.screenshot({ path: 'artifacts/orbit-expanded.png', fullPage: true });
  await page.getByRole('button', { name: 'Закрыть Скриншот' }).click();
  await expect(page.getByTestId('orbit-event')).toHaveCount(2);
  await page.getByRole('button', { name: 'Вернуть всё в чёлку' }).click();
  await expect(page.getByTestId('orbit-event')).toHaveCount(0);
  await expect(page.getByText('Всё важное — внутри')).toBeVisible();
  await page.getByRole('button', { name: 'Вернуть события из чёлки (2)' }).click();
  await expect(page.getByTestId('orbit-event')).toHaveCount(2);
});

test('Orbit: six-event limit stays scrollable and Escape parks the queue', async ({ page }) => {
  await page.goto('/'); await switchTo(page, 'Orbit');
  for (let i = 0; i < 6; i++) await page.getByRole('button', { name: 'Codex', exact: true }).click();
  await expect(page.getByTestId('orbit-event')).toHaveCount(6);
  const dimensions = await page.getByTestId('orbit-stack').evaluate(n => ({ h: n.clientHeight, scroll: n.scrollHeight }));
  expect(dimensions.scroll).toBeGreaterThan(dimensions.h);
  await page.keyboard.press('Escape'); await page.keyboard.press('Escape');
  await expect(page.getByTestId('orbit-event')).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Вернуть события из чёлки (6)' })).toBeEnabled();
});

test('Shelf: real file input, preview, download and removal', async ({ page }) => {
  await page.goto('/'); await switchTo(page, 'Shelf');
  await page.getByTestId('file-input').setInputFiles({ name: 'real-notes.txt', mimeType: 'text/plain', buffer: Buffer.from('Real local file. Привет, полка!') });
  await expect(page.getByRole('button', { name: 'Просмотреть real-notes.txt' })).toBeVisible();
  await page.getByRole('button', { name: 'Просмотреть real-notes.txt' }).click();
  await expect(page.getByRole('dialog')).toBeVisible();
  await expect(page.getByText('Real local file. Привет, полка!')).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(page.getByRole('dialog')).toHaveCount(0);
  const downloadPromise = page.waitForEvent('download');
  await page.getByRole('link', { name: 'Скачать real-notes.txt' }).click();
  expect((await downloadPromise).suggestedFilename()).toBe('real-notes.txt');
  await page.getByRole('button', { name: 'Удалить real-notes.txt' }).click();
  await expect(page.getByRole('button', { name: 'Просмотреть real-notes.txt' })).toHaveCount(0);
  await expect(page.getByText('Место для ваших файлов')).toBeVisible();
});

test('Shelf: native DataTransfer file drop and magnetic proximity', async ({ page }) => {
  await page.goto('/'); await switchTo(page, 'Shelf');
  const zone = page.getByTestId('shelf-dropzone');
  await expect(zone).toBeVisible();
  await page.getByRole('button', { name: 'Свернуть полку', exact: true }).first().click();
  await stable(page);
  const rect = await zone.boundingBox();
  const transfer = await page.evaluateHandle(() => { const data = new DataTransfer(); data.items.add(new File(['Dropped from Finder'], 'finder-drop.txt', { type: 'text/plain' })); return data; });
  await page.locator('.desktop').dispatchEvent('dragenter', { dataTransfer: transfer, clientX: rect!.x + 200, clientY: rect!.y + 200 });
  await expect(zone).toHaveAttribute('data-magnetic', 'true');
  expect((await zone.boundingBox())!.height).toBeLessThan(50);
  await zone.dispatchEvent('dragover', { dataTransfer: transfer, clientX: rect!.x + 200, clientY: rect!.y + 110 });
  await expect(zone).toHaveClass(/is-near/);
  await stable(page);
  const magnetized = await zone.boundingBox();
  expect(magnetized!.y).toBeCloseTo(rect!.y, 0);
  await zone.dispatchEvent('drop', { dataTransfer: transfer });
  await expect(page.getByRole('button', { name: 'Просмотреть finder-drop.txt' })).toBeVisible();
  await expect(zone).toHaveAttribute('data-magnetic', 'false');
  const outgoing = await page.evaluate(() => { const data = new DataTransfer(); document.querySelector('.shelf-file')!.dispatchEvent(new DragEvent('dragstart', { bubbles: true, dataTransfer: data })); return { download: data.getData('DownloadURL'), uri: data.getData('text/uri-list') }; });
  expect(outgoing.download).toContain('text/plain:finder-drop.txt:blob:');
  expect(outgoing.uri).toContain('blob:');
});

test('Shelf: demo files, image quick look, collapse, hover and screenshots', async ({ page }) => {
  await page.goto('/'); await switchTo(page, 'Shelf');
  await page.getByRole('button', { name: 'Демо-файлы', exact: true }).click();
  await expect(page.locator('.shelf-file')).toHaveCount(2);
  await page.getByRole('button', { name: 'Просмотреть Orbit study.svg' }).click();
  await expect(page.getByRole('dialog').getByRole('img', { name: 'Orbit study.svg' })).toBeVisible();
  await page.keyboard.press('Escape'); await stable(page);
  const notch = await page.getByTestId('shelf-dropzone').boundingBox();
  const content = await page.locator('.shelf-content').boundingBox();
  expect(content!.y + content!.height).toBeLessThanOrEqual(notch!.y + notch!.height + 1);
  await page.screenshot({ path: 'artifacts/shelf-expanded.png', fullPage: true });
  await page.getByRole('button', { name: 'Свернуть полку', exact: true }).first().click();
  await page.getByRole('button', { name: 'Раскрыть полку', exact: true }).first().click();
  await expect(page.locator('.shelf-file')).toHaveCount(2);
  await page.getByRole('button', { name: 'Поднести файл', exact: true }).click();
  await expect(page.getByTestId('shelf-dropzone')).toHaveAttribute('data-magnetic', 'true');
  await page.keyboard.press('Escape');
  await expect(page.getByTestId('shelf-dropzone')).toHaveAttribute('data-magnetic', 'false');
});

test('Motion settings, replay, tabs, focus mode and about', async ({ page }) => {
  await page.goto('/');
  await page.getByRole('switch', { name: 'Замедлить' }).click();
  await expect(page.getByRole('switch', { name: 'Замедлить' })).toHaveAttribute('aria-checked', 'true');
  await page.getByRole('button', { name: 'Меньше движения' }).click();
  await expect(page.locator('main')).toHaveAttribute('data-reduced', 'true');
  await page.getByRole('button', { name: 'Компактно', exact: true }).click();
  await page.getByRole('button', { name: 'Повторить сцену' }).click();
  await expect(page.getByTestId('liquid-notch')).toHaveAttribute('data-state', 'expanded');
  await switchTo(page, 'Liquid');
  await expect(page.getByRole('button', { name: 'Компактно', exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'Фокус-режим', exact: true }).click();
  await expect(page.locator('main')).toHaveClass(/focus-mode/);
  await page.keyboard.press('Escape');
  await expect(page.locator('main')).not.toHaveClass(/focus-mode/);
  await page.getByRole('button', { name: 'Об эксперименте' }).click();
  await expect(page.getByRole('dialog', { name: 'Об эксперименте' })).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(page.getByRole('dialog')).toHaveCount(0);
});

test('OS reduced motion disables decorative animation', async ({ page }) => {
  await page.emulateMedia({ reducedMotion: 'reduce' }); await page.goto('/');
  await expect(page.locator('main')).toHaveAttribute('data-reduced', 'true');
  await expect(page.getByRole('button', { name: 'Меньше движения' })).toBeDisabled();
  expect(await page.locator('.wave i').first().evaluate(e => getComputedStyle(e).animationName)).toBe('none');
  await switchTo(page, 'Orbit'); await expect(page.getByTestId('orbit-event')).toHaveCount(2);
  await switchTo(page, 'Shelf'); await expect(page.getByText('Место для ваших файлов')).toBeVisible();
});

for (const width of [390, 768]) test(`Responsive ${width}: no page overflow and notch content stays inside`, async ({ page }) => {
  await page.setViewportSize({ width, height: 1000 });
  await page.goto('/');
  for (const concept of ['Liquid', 'Orbit', 'Shelf']) {
    await switchTo(page, concept); await stable(page);
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width);
    const scene = await page.locator('.desktop').boundingBox();
    const surface = await page.locator('.notch').boundingBox();
    expect(surface!.x).toBeGreaterThanOrEqual(scene!.x);
    expect(surface!.x + surface!.width).toBeLessThanOrEqual(scene!.x + scene!.width);
    if (concept === 'Shelf') { await page.getByRole('button', { name: 'Демо-файлы', exact: true }).click(); await stable(page); }
    await page.screenshot({ path: `artifacts/${concept.toLowerCase()}-${width}.png`, fullPage: true });
  }
});


test('Shelf keeps actual files across concept switches and replay', async ({ page }) => {
  await page.goto('/'); await switchTo(page, 'Shelf');
  await page.getByTestId('file-input').setInputFiles({ name: 'persistent.txt', mimeType: 'text/plain', buffer: Buffer.from('Kept in this tab') });
  await switchTo(page, 'Liquid'); await expect(page.getByTestId('liquid-notch')).toBeVisible();
  await switchTo(page, 'Shelf');
  await expect(page.getByRole('button', { name: 'Просмотреть persistent.txt' })).toBeVisible();
  await page.getByRole('button', { name: 'Повторить сцену' }).click();
  await expect(page.getByRole('button', { name: 'Просмотреть persistent.txt' })).toBeVisible();
});

test('Keyboard concept navigation and modal focus trap', async ({ page }) => {
  await page.goto('/'); await page.keyboard.press('2');
  await expect(page.getByRole('tab', { name: /Orbit/ })).toHaveAttribute('aria-selected', 'true');
  await page.getByRole('tab', { name: /Orbit/ }).focus(); await page.keyboard.press('ArrowRight');
  await expect(page.getByRole('tab', { name: /Shelf/ })).toBeFocused();
  await page.keyboard.press('1');
  await expect(page.getByRole('tab', { name: /Liquid/ })).toHaveAttribute('aria-selected', 'true');
  await page.getByRole('button', { name: 'Об эксперименте' }).click();
  await expect(page.getByRole('button', { name: 'Закрыть описание' })).toBeFocused();
  await page.keyboard.press('Shift+Tab');
  expect(await page.getByRole('dialog').evaluate(n => n.contains(document.activeElement))).toBe(true);
  await page.keyboard.press('Tab');
  await expect(page.getByRole('button', { name: 'Закрыть описание' })).toBeFocused();
  await page.keyboard.press('Escape');
  await expect(page.getByRole('button', { name: 'Об эксперименте' })).toBeFocused();
});

test('Spring morph interpolates continuously and remains anchored', async ({ page }) => {
  await page.goto('/');
  await page.getByRole('button', { name: 'Компактно', exact: true }).click(); await stable(page);
  await page.mouse.move(30, 30);
  const samples = await page.evaluate(async () => {
    const notch = document.querySelector('[data-testid=liquid-notch]')!;
    const button = [...document.querySelectorAll('button')].find(b => b.textContent === 'Раскрыто')!;
    const frames: { width: number; height: number; top: number }[] = [];
    const start = performance.now(); button.click();
    while (performance.now() - start < 700) {
      await new Promise(requestAnimationFrame);
      const rect = notch.getBoundingClientRect(); frames.push({ width: rect.width, height: rect.height, top: rect.top });
    }
    return frames;
  });
  expect(new Set(samples.map(s => Math.round(s.width))).size).toBeGreaterThan(5);
  for (let i = 1; i < samples.length; i++) {
    expect(Math.abs(samples[i].width - samples[i - 1].width)).toBeLessThan(85);
    expect(Math.abs(samples[i].height - samples[i - 1].height)).toBeLessThan(85);
    expect(samples[i].top).toBeCloseTo(samples[0].top, 0);
  }
});
