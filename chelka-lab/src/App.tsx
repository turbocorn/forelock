import { useCallback, useEffect, useRef, useState } from 'react';
import type { Dispatch, DragEvent, ReactNode, RefObject, SetStateAction } from 'react';
import { AnimatePresence, MotionConfig, motion, useReducedMotion } from 'motion/react';
import { ArrowDownToLine, ArrowLeft, ArrowRight, ArrowUpRight, AudioLines, BatteryFull, Check, ChevronDown, ChevronUp, CircleCheck, Command, Expand, FileImage, FileText, Folder, Headphones, Layers2, Maximize2, MousePointer2, Pause, Play, Plus, RotateCcw, ScanLine, Settings2, SkipBack, SkipForward, Sparkles, Volume2, VolumeX, Wifi, X } from 'lucide-react';

type Concept = 'liquid' | 'orbit' | 'shelf';
type Size = 'compact' | 'mini' | 'expanded';
type EventKind = 'codex' | 'airpods' | 'screenshot';
type OrbitEvent = { id: number; kind: EventKind; parked: boolean };
type ShelfFile = { id: string; file: globalThis.File; url: string };
type ShelfStorage = { files: ShelfFile[]; setFiles: Dispatch<SetStateAction<ShelfFile[]>>; urls: RefObject<Set<string>> };
type LabProps = { controls: (node: ReactNode) => void; reduced: boolean; slow: boolean; reset: number };

const concepts: { id: Concept; number: string; name: string; tag: string; description: string; cue: string }[] = [
  { id: 'liquid', number: '01', name: 'Liquid', tag: 'Одна форма. Любое состояние.', description: 'Музыка, которая обретает форму. От тихого присутствия до полноценного плеера — одним непрерывным движением.', cue: 'Наведите на чёлку или нажмите, чтобы раскрыть плеер' },
  { id: 'orbit', number: '02', name: 'Orbit', tag: 'Всё важное — на своей орбите.', description: 'Небольшие события появляются рядом, когда нужны. Раскройте подробности, верните в чёлку или просто отпустите.', cue: 'Добавляйте события и управляйте их орбитами' },
  { id: 'shelf', number: '03', name: 'Shelf', tag: 'Место для того, что под рукой.', description: 'Поднесите файл — чёлка потянется навстречу. Оставьте его на временной полке и заберите, когда понадобится.', cue: 'Перетащите файл из Finder к чёлке' },
];
const eventMeta = {
  codex: { name: 'Codex', title: 'Задача завершена', detail: 'Готово к вашему вниманию', body: 'Компонент Navigation обновлён. 4 файла изменены, все проверки пройдены.', color: '#c4e4a1', Icon: Command },
  airpods: { name: 'AirPods Pro', title: 'Снова вместе', detail: 'Подключены к этому Mac', body: 'Пространственное аудио включено. Музыка продолжится в наушниках.', color: '#cfcefa', Icon: Headphones },
  screenshot: { name: 'Скриншот', title: 'Момент сохранён', detail: 'Сегодня, только что', body: 'Снимок экрана сохранён на рабочий стол. Можно продолжать работу.', color: '#f0c49d', Icon: ScanLine },
};
const tracks = [
  { title: 'A Place Between', artist: 'Quiet Form', album: 'Soft Focus — EP', duration: 238 },
  { title: 'Slow Morning', artist: 'Quiet Form', album: 'Soft Focus — EP', duration: 204 },
  { title: 'Weightless', artist: 'Quiet Form', album: 'Soft Focus — EP', duration: 267 },
];
const clock = (seconds: number) => `${Math.floor(seconds / 60)}:${String(Math.floor(seconds % 60)).padStart(2, '0')}`;

function Wave({ playing = true }: { playing?: boolean }) {
  return <span className={`wave ${playing ? 'playing' : ''}`} aria-hidden="true">{[0, 1, 2, 3, 4].map(i => <i key={i} style={{ animationDelay: `${i * -.17}s` }} />)}</span>;
}
function Camera() { return <div className="camera-space" aria-hidden="true"><span className="camera-lens" /></div>; }
function Key({ children }: { children: ReactNode }) { return <kbd>{children}</kbd>; }
function SectionLabel({ children }: { children: ReactNode }) { return <span className="control-label">{children}</span>; }
function IconButton({ label, children, onClick, className = '', ...rest }: { label: string; children: ReactNode; onClick?: () => void; className?: string; disabled?: boolean; 'aria-expanded'?: boolean }) {
  return <button type="button" title={label} aria-label={label} className={`icon-button ${className}`} onClick={onClick} {...rest}>{children}</button>;
}
function useEscape(callback: () => void) {
  const cb = useRef(callback); cb.current = callback;
  useEffect(() => { const listener = (e: KeyboardEvent) => { if (e.key === 'Escape') cb.current(); }; window.addEventListener('keydown', listener); return () => window.removeEventListener('keydown', listener); }, []);
}

function useModalFocus(open: boolean, ref: RefObject<HTMLElement | null>) {
  useEffect(() => {
    if (!open) return;
    const previous = document.activeElement as HTMLElement | null;
    const frame = requestAnimationFrame(() => ref.current?.querySelector<HTMLElement>('button, a[href], input')?.focus());
    const trap = (event: KeyboardEvent) => {
      if (event.key !== 'Tab' || !ref.current) return;
      const elements = [...ref.current.querySelectorAll<HTMLElement>('button:not([disabled]), a[href], input, [tabindex="0"]')];
      const first = elements[0]; const last = elements.at(-1);
      if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus(); }
      else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus(); }
    };
    document.addEventListener('keydown', trap);
    return () => { cancelAnimationFrame(frame); document.removeEventListener('keydown', trap); if (previous?.isConnected) previous.focus(); };
  }, [open, ref]);
}

function Liquid({ controls, reduced, slow }: LabProps) {
  const [size, setSize] = useState<Size>('expanded');
  const [hover, setHover] = useState(false);
  const [playing, setPlaying] = useState(true);
  const [trackIndex, setTrackIndex] = useState(0);
  const [progress, setProgress] = useState(79);
  const [volume, setVolume] = useState(68);
  const [muted, setMuted] = useState(false);
  const track = tracks[trackIndex];
  const displayed = size === 'compact' && hover ? 'mini' : size;
  const changeTrack = useCallback((direction: number) => { setTrackIndex(i => (i + direction + tracks.length) % tracks.length); setProgress(0); }, []);
  useEscape(() => { setSize('compact'); setHover(false); });
  useEffect(() => {
    if (!playing) return;
    const id = window.setInterval(() => setProgress(p => p >= track.duration ? 0 : p + 1), 1000);
    return () => clearInterval(id);
  }, [playing, track.duration]);
  useEffect(() => controls(<>
    <div className="control-group"><SectionLabel>Состояние</SectionLabel><div className="segmented" aria-label="Размер плеера">{(['compact', 'mini', 'expanded'] as Size[]).map((s, i) => <button key={s} className={size === s ? 'selected' : ''} onClick={() => { setHover(false); setSize(s); }} aria-pressed={size === s}>{['Компактно', 'Мини', 'Раскрыто'][i]}</button>)}</div></div>
    <div className="control-group"><SectionLabel>Воспроизведение</SectionLabel><button className="control-button" onClick={() => setPlaying(p => !p)}>{playing ? <Pause aria-hidden="true" size={14} /> : <Play aria-hidden="true" size={14} />}{playing ? 'Поставить на паузу' : 'Продолжить'}</button></div>
    <div className="control-group next-track"><SectionLabel>Сценарий</SectionLabel><button className="control-button" onClick={() => changeTrack(1)}><SkipForward aria-hidden="true" size={14} />Следующий трек</button></div>
  </>), [controls, size, playing, changeTrack]);
  const widths = { compact: 206, mini: 330, expanded: 420 };
  const heights = { compact: 39, mini: 87, expanded: 260 };
  return <div className="notch-anchor liquid-anchor">
    <motion.div className={`notch liquid-notch is-${displayed}`} data-testid="liquid-notch" data-state={displayed}
      animate={{ width: widths[displayed], height: heights[displayed], borderBottomLeftRadius: displayed === 'expanded' ? 30 : 22, borderBottomRightRadius: displayed === 'expanded' ? 30 : 22 }}
      initial={{ width: 184, height: 30 }}
      onHoverStart={() => setHover(true)} onHoverEnd={() => setHover(false)}>
      <div className="notch-interior"><Camera />
      <AnimatePresence mode="popLayout" initial={false}>
        {displayed === 'compact' && <motion.button key="compact" className="compact-player" aria-label="Раскрыть плеер" onClick={() => setSize('expanded')} initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }}><img src="/artwork.svg" alt="" /><Wave playing={playing} /></motion.button>}
        {displayed === 'mini' && <motion.div key="mini" className="mini-player" initial={{ opacity: 0, y: -8 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: -5 }} transition={{ duration: reduced ? 0 : .18 }}>
          <button className="mini-track" onClick={() => setSize('expanded')} aria-label="Раскрыть плеер"><img src="/artwork.svg" alt="Обложка Quiet Form" /><span><b>{track.title}</b><small>{track.artist}</small></span></button>
          <IconButton label={playing ? 'Пауза' : 'Воспроизвести'} onClick={() => setPlaying(p => !p)}>{playing ? <Pause aria-hidden="true" size={19} fill="currentColor" /> : <Play aria-hidden="true" size={19} fill="currentColor" />}</IconButton><IconButton label="Увеличить плеер" onClick={() => setSize('expanded')}><Expand aria-hidden="true" size={15} /></IconButton>
        </motion.div>}
        {displayed === 'expanded' && <motion.div key="expanded" className="expanded-player" initial={{ opacity: 0, y: -12, scale: .94 }} animate={{ opacity: 1, y: 0, scale: 1 }} exit={{ opacity: 0, y: -10, scale: .95 }} transition={{ duration: reduced ? 0 : slow ? .4 : .23 }}>
          <div className="player-topline"><span><i style={{ background: playing ? '#bad492' : '#646e59' }} />{playing ? 'СЕЙЧАС ИГРАЕТ' : 'НА ПАУЗЕ'}</span><IconButton label="Свернуть плеер" onClick={() => { setSize('compact'); setHover(false); }}><ChevronUp aria-hidden="true" size={15} /></IconButton></div>
          <div className="track-row"><motion.img key={trackIndex} initial={{ opacity: .35, scale: .9 }} animate={{ opacity: 1, scale: 1 }} className="album-cover" src="/artwork.svg" alt="Обложка альбома Soft Focus" /><div className="track-info"><AnimatePresence mode="wait"><motion.div key={track.title} initial={{ opacity: 0, y: 5 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: -5 }}><h2>{track.title}</h2><p>{track.artist}</p><small>{track.album}</small></motion.div></AnimatePresence></div><Wave playing={playing} /></div>
          <div className="seek"><input aria-label="Прогресс трека" type="range" min="0" max={track.duration} value={progress} onChange={e => setProgress(Number(e.target.value))} style={{ '--fill': `${progress / track.duration * 100}%` } as React.CSSProperties} /><div><span>{clock(progress)}</span><span>−{clock(track.duration - progress)}</span></div></div>
          <div className="playback-row"><span className="output-label"><Headphones aria-hidden="true" size={13} />MacBook</span><div className="transport"><IconButton label="Предыдущий трек" onClick={() => changeTrack(-1)}><SkipBack aria-hidden="true" size={19} fill="currentColor" /></IconButton><IconButton label={playing ? 'Пауза' : 'Воспроизвести'} className="play-button" onClick={() => setPlaying(p => !p)}>{playing ? <Pause aria-hidden="true" size={19} fill="currentColor" /> : <Play aria-hidden="true" size={19} fill="currentColor" />}</IconButton><IconButton label="Следующий трек" onClick={() => changeTrack(1)}><SkipForward aria-hidden="true" size={19} fill="currentColor" /></IconButton></div><div className="volume"><IconButton label={muted ? 'Включить звук' : 'Выключить звук'} onClick={() => setMuted(m => !m)}>{muted ? <VolumeX aria-hidden="true" size={15} /> : <Volume2 aria-hidden="true" size={15} />}</IconButton><input aria-label="Громкость" type="range" min="0" max="100" value={muted ? 0 : volume} onChange={e => { setVolume(Number(e.target.value)); setMuted(false); }} style={{ '--fill': `${muted ? 0 : volume}%` } as React.CSSProperties} /></div></div>
        </motion.div>}
      </AnimatePresence></div>
    </motion.div>
    <motion.div className="notch-state" key={displayed} initial={{ opacity: 0 }} animate={{ opacity: 1 }} style={{ top: heights[displayed] + 24 }}><span />{displayed === 'expanded' ? 'Музыка на первом плане' : displayed === 'mini' ? 'Чуть больше, чем присутствие' : 'Тихое присутствие'}</motion.div>
  </div>;
}

function Orbit({ controls, reduced, slow }: LabProps) {
  const [events, setEvents] = useState<OrbitEvent[]>([{ id: 1, kind: 'codex', parked: false }, { id: 2, kind: 'airpods', parked: false }]);
  const [expanded, setExpanded] = useState<number | null>(1);
  const counter = useRef(3);
  const stackRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (expanded === null) return;
    const timer = window.setTimeout(() => {
      const card = stackRef.current?.querySelector<HTMLElement>(`[data-event-id="${expanded}"]`);
      if (card && stackRef.current) {
        const bottom = card.offsetTop + card.offsetHeight;
        if (bottom > stackRef.current.scrollTop + stackRef.current.clientHeight) stackRef.current.scrollTo({ top: bottom - stackRef.current.clientHeight + 8, behavior: reduced ? 'instant' : 'smooth' });
        if (card.offsetTop < stackRef.current.scrollTop) stackRef.current.scrollTo({ top: card.offsetTop, behavior: reduced ? 'instant' : 'smooth' });
      }
    }, reduced ? 0 : 320);
    return () => clearTimeout(timer);
  }, [expanded, reduced]);
  const [notice, setNotice] = useState('');
  const active = events.filter(e => !e.parked);
  const parked = events.filter(e => e.parked);
  const add = useCallback((kind: EventKind) => {
    setNotice('');
    const id = counter.current++;
    setEvents(prev => [...prev, { id, kind, parked: false }].slice(-6));
    setExpanded(id);
  }, []);
  const park = (id: number) => { setEvents(prev => prev.map(e => e.id === id ? { ...e, parked: true } : e)); setExpanded(null); };
  const remove = (id: number) => { setEvents(prev => prev.filter(e => e.id !== id)); if (expanded === id) setExpanded(null); };
  const restore = () => { setEvents(prev => prev.map(e => ({ ...e, parked: false }))); if (parked.length) setExpanded(parked[0].id); };
  useEscape(() => { if (expanded !== null) setExpanded(null); else setEvents(prev => prev.map(e => ({ ...e, parked: true }))); });
  useEffect(() => controls(<>
    <div className="control-group event-controls"><SectionLabel>Добавить событие</SectionLabel><div className="button-row">{(Object.keys(eventMeta) as EventKind[]).map(kind => { const { Icon, name } = eventMeta[kind]; return <button className="control-button" key={kind} onClick={() => add(kind)}><Icon aria-hidden="true" size={14} />{name}<Plus aria-hidden="true" size={12} /></button>; })}</div></div>
    <div className="control-group"><SectionLabel>Управление орбитой</SectionLabel><button className="control-button" disabled={!active.length} onClick={() => { setEvents(prev => prev.map(e => ({ ...e, parked: true }))); setExpanded(null); }}><ArrowUpRight aria-hidden="true" size={15} />Вернуть всё в чёлку</button></div>
  </>), [controls, add, active.length]);
  return <div className="notch-anchor orbit-anchor">
    <motion.div className="notch orbit-notch" initial={{ width: 184 }} animate={{ width: parked.length ? 224 : 184 }}><Camera /><button className="orbit-home" aria-label={`Вернуть события из чёлки (${parked.length})`} disabled={!parked.length} onClick={restore}><span className="orbit-signal"><i /><i /><i /></span>{parked.length > 0 && <span className="parked-count">{parked.length}</span>}</button></motion.div>
    <div className="orbit-stack" ref={stackRef} data-testid="orbit-stack">
      <AnimatePresence>
        {active.map((event, i) => {
          const meta = eventMeta[event.kind]; const isOpen = expanded === event.id;
          const origin = -60 - active.slice(0, i).reduce((height, previous) => height + (expanded === previous.id ? 160 : 64) + 8, 0);
          return <motion.article layout="position" key={event.id} className={`orbit-card ${isOpen ? 'is-expanded' : ''}`} data-testid="orbit-event" data-event-id={event.id} data-kind={event.kind}
            style={{ transformOrigin: '50% 0' }} initial={{ opacity: 0, y: origin, scale: .55, filter: 'blur(5px)' }} animate={{ opacity: 1, y: 0, scale: 1, filter: 'blur(0px)' }} exit={{ opacity: 0, y: origin, scale: .25, filter: 'blur(4px)', transition: { duration: reduced ? 0 : slow ? .75 : .32 } }}>
            <div className="orbit-card-top"><button className="event-trigger" aria-expanded={isOpen} aria-label={`Раскрыть ${meta.name}`} onClick={() => setExpanded(isOpen ? null : event.id)}><span className={`event-icon ${event.kind}`} style={{ color: meta.color }}><meta.Icon aria-hidden="true" size={20} /></span><span className="event-heading"><span>{meta.name}<small>сейчас</small></span><b>{meta.title}</b></span></button><div className="event-actions"><IconButton label={`Вернуть ${meta.name} в чёлку`} onClick={() => park(event.id)}><ChevronUp aria-hidden="true" size={15} /></IconButton><IconButton label={`Закрыть ${meta.name}`} onClick={() => remove(event.id)}><X aria-hidden="true" size={14} /></IconButton></div></div>
            <AnimatePresence initial={false}>{isOpen && <motion.div key="details" className="event-details" initial={{ height: 0, opacity: 0 }} animate={{ height: 'auto', opacity: 1 }} exit={{ height: 0, opacity: 0 }}><p>{meta.body}</p>{event.kind === 'airpods' ? <div className="airpods-battery"><Headphones aria-hidden="true" size={15} /><span>Левый <b>94%</b></span><span>Правый <b>96%</b></span><BatteryFull aria-hidden="true" size={20} /></div> : event.kind === 'screenshot' ? <div className="screenshot-preview"><div /><span>Снимок экрана · 2560 × 1600</span></div> : <div className="codex-result"><span><CircleCheck aria-hidden="true" size={13} />4 файла · проверки пройдены</span><button onClick={() => { setNotice('Результат просмотрен. Событие сохранено в чёлке.'); park(event.id); }} aria-label="Принять результат Codex">Принять<ArrowUpRight aria-hidden="true" size={12} /></button></div>}</motion.div>}</AnimatePresence>
          </motion.article>;
        })}
      </AnimatePresence>
      {!active.length && <motion.div className="orbit-empty" initial={{ opacity: 0 }} animate={{ opacity: 1 }}><Sparkles aria-hidden="true" size={24} strokeWidth={1} /><p>{parked.length ? 'Всё важное — внутри' : 'Пока тихо'}</p><span>{parked.length ? 'Нажмите на чёлку, чтобы вернуть события' : 'Добавьте событие в панели внизу'}</span></motion.div>}
    </div>
    <div className="orbit-announcement" role="status">{notice}</div>
  </div>;
}

const demoFiles = () => [
  new globalThis.File(['Чёлка — заметки к прототипу\n\nДвижение начинается с намерения.\nLiquid: непрерывная форма.\nOrbit: независимые события.\nShelf: магнитное притяжение.'], 'Заметки.txt', { type: 'text/plain' }),
  new globalThis.File(['<svg xmlns="http://www.w3.org/2000/svg" width="640" height="480"><rect width="640" height="480" fill="#dbe0d0"/><circle cx="320" cy="240" r="150" fill="#344b3a"/><circle cx="320" cy="240" r="94" fill="#b9d19c"/><text x="320" y="248" text-anchor="middle" fill="#243a29" font-size="22" font-family="sans-serif">Чёлка</text></svg>'], 'Orbit study.svg', { type: 'image/svg+xml' }),
];
function FileGlyph({ file }: { file: globalThis.File }) {
  return <span className={`file-glyph ${file.type.startsWith('image/') ? 'is-image' : ''}`}>{file.type.startsWith('image/') ? <FileImage aria-hidden="true" size={24} strokeWidth={1.3} /> : <FileText aria-hidden="true" size={24} strokeWidth={1.3} />}</span>;
}
function Shelf({ controls, reduced, files, setFiles, urls }: LabProps & ShelfStorage) {
  const [open, setOpen] = useState(true);
  const [dragging, setDragging] = useState(false);
  const [near, setNear] = useState(false);
  const [offset, setOffset] = useState({ x: 0, y: 0 });
  const [preview, setPreview] = useState<ShelfFile | null>(null);
  const [text, setText] = useState('');
  const [status, setStatus] = useState('');
  const [demo, setDemo] = useState(false);
  const previewRef = useRef<HTMLElement>(null);
  useModalFocus(Boolean(preview), previewRef);
  const zone = useRef<HTMLDivElement>(null);
  const input = useRef<HTMLInputElement>(null);
  const dragDepth = useRef(0);
  const addFiles = useCallback((incoming: globalThis.File[]) => {
    if (!incoming.length) return;
    const accepted = incoming.filter(file => file.size <= 100 * 1024 * 1024);
    const newFiles = accepted.map(file => { const url = URL.createObjectURL(file); urls.current.add(url); return { id: crypto.randomUUID(), file, url }; });
    setFiles(previous => [...previous, ...newFiles]); setOpen(true); setDragging(false); setNear(false); setOffset({ x: 0, y: 0 });
    setStatus(accepted.length < incoming.length ? `Добавлено: ${accepted.length}. Файлы больше 100 МБ пропущены.` : `На полке: +${accepted.length}`);
  }, [setFiles, urls]);
  const addDemo = useCallback(() => { addFiles(demoFiles()); }, [addFiles]);
  useEffect(() => {
    const isFiles = (e: globalThis.DragEvent) => Boolean(e.dataTransfer?.types.includes('Files'));
    const enter = (e: globalThis.DragEvent) => { if (isFiles(e)) { e.preventDefault(); dragDepth.current++; setDragging(true); } };
    const leave = (e: globalThis.DragEvent) => { if (isFiles(e) && --dragDepth.current <= 0) { dragDepth.current = 0; setDragging(false); setNear(false); setOffset({ x: 0, y: 0 }); } };
    const over = (e: globalThis.DragEvent) => {
      if (!isFiles(e)) return; e.preventDefault();
      const rect = zone.current?.getBoundingClientRect(); if (!rect) return;
      const dx = e.clientX - (rect.left + rect.width / 2); const dy = e.clientY - rect.top;
      const attracted = Math.abs(dx) < 300 && dy > -70 && dy < 300;
      setNear(attracted); setOffset(attracted && !reduced ? { x: Math.max(-18, Math.min(18, dx * .07)), y: Math.max(0, Math.min(16, dy * .06)) } : { x: 0, y: 0 });
    };
    const drop = (e: globalThis.DragEvent) => { if (!isFiles(e)) return; e.preventDefault(); dragDepth.current = 0; setDragging(false); setNear(false); setOffset({ x: 0, y: 0 }); };
    window.addEventListener('dragenter', enter); window.addEventListener('dragleave', leave); window.addEventListener('dragover', over); window.addEventListener('drop', drop);
    return () => { window.removeEventListener('dragenter', enter); window.removeEventListener('dragleave', leave); window.removeEventListener('dragover', over); window.removeEventListener('drop', drop); };
  }, [reduced]);
  useEscape(() => { if (preview) setPreview(null); else { setOpen(false); setDragging(false); setDemo(false); setNear(false); dragDepth.current = 0; setOffset({ x: 0, y: 0 }); } });
  const remove = (id: string) => { setFiles(prev => prev.filter(f => { if (f.id === id) { URL.revokeObjectURL(f.url); urls.current.delete(f.url); return false; } return true; })); setStatus('Файл убран с полки'); };
  const inspect = async (item: ShelfFile) => { setText(''); setPreview(item); if (item.file.type.startsWith('text/') || /\.(md|json|csv)$/i.test(item.file.name)) setText((await item.file.text()).slice(0, 30000)); };
  const startDrag = (e: DragEvent, item: ShelfFile) => { e.dataTransfer.setData('DownloadURL', `${item.file.type || 'application/octet-stream'}:${item.file.name}:${item.url}`); e.dataTransfer.setData('text/uri-list', item.url); e.dataTransfer.setData('text/plain', item.file.name); e.dataTransfer.effectAllowed = 'copy'; };
  useEffect(() => controls(<>
    <div className="control-group"><SectionLabel>Добавить на полку</SectionLabel><div className="button-row"><button className="control-button" onClick={() => input.current?.click()}><Plus aria-hidden="true" size={14} />Выбрать файлы</button><button className="control-button" onClick={addDemo}><FileText aria-hidden="true" size={14} />Демо-файлы</button></div></div>
    <div className="control-group"><SectionLabel>Магнитное поле</SectionLabel><button className={`control-button ${demo ? 'is-active' : ''}`} aria-pressed={demo} onClick={() => { setDemo(d => !d); setNear(n => !n); }}><MousePointer2 aria-hidden="true" size={14} />{demo ? 'Завершить симуляцию' : 'Поднести файл'}</button></div>
    <div className="control-group"><SectionLabel>Состояние</SectionLabel><button className="control-button" onClick={() => setOpen(o => !o)}>{open ? <ChevronUp aria-hidden="true" size={14} /> : <ChevronDown aria-hidden="true" size={14} />}{open ? 'Свернуть полку' : 'Раскрыть полку'}</button></div>
  </>), [controls, open, addDemo, demo]);
  const magnet = dragging || demo;
  const expanded = open || near || demo;
  return <>
    <input ref={input} type="file" multiple hidden onChange={e => { addFiles(Array.from(e.target.files || [])); e.target.value = ''; }} data-testid="file-input" />
    <div className="notch-anchor shelf-anchor" ref={zone}>
      <motion.div className={`notch shelf-notch ${magnet ? 'is-magnetic' : ''} ${near ? 'is-near' : ''}`} data-testid="shelf-dropzone" data-magnetic={magnet}
        initial={{ width: 184, height: 37 }} animate={{ width: expanded ? 440 + Math.abs(offset.x) * .5 : 214, height: expanded ? (files.length ? 288 : 242) + offset.y * .4 : 41 }}
        onDragOver={e => { if (e.dataTransfer.types.includes('Files')) { e.preventDefault(); e.dataTransfer.dropEffect = 'copy'; } }}
        onDrop={e => { if (e.dataTransfer.files.length) { e.preventDefault(); addFiles(Array.from(e.dataTransfer.files)); setDemo(false); dragDepth.current = 0; } }}>
        <div className="notch-interior"><Camera />
        {!expanded && <button className="shelf-compact" aria-label="Раскрыть полку" onClick={() => setOpen(true)}><Layers2 aria-hidden="true" size={15} /><span>{files.length || ''}</span></button>}
        <AnimatePresence>{expanded && <motion.div className="shelf-content" key="shelf" initial={{ opacity: 0, y: -12 }} animate={{ opacity: 1, x: offset.x * .25, y: offset.y * .2 }} exit={{ opacity: 0, y: -12 }}>
          <div className="shelf-heading"><span><Layers2 aria-hidden="true" size={15} />Временная полка <b>{files.length.toString().padStart(2, '0')}</b></span><IconButton label="Свернуть полку" onClick={() => { setOpen(false); setDemo(false); setNear(false); }}><ChevronUp aria-hidden="true" size={15} /></IconButton></div>
          {files.length ? <div className="shelf-files" data-testid="shelf-files"><AnimatePresence initial={false}>{files.map(item => <motion.div layout key={item.id} className="shelf-file" initial={{ opacity: 0, y: -30, scale: .7 }} animate={{ opacity: 1, y: 0, scale: 1 }} exit={{ opacity: 0, scale: .7 }} draggable onDragStartCapture={e => startDrag(e, item)} title="Перетащите файл из полки"><button className="file-preview-button" onClick={() => void inspect(item)} aria-label={`Просмотреть ${item.file.name}`}><FileGlyph file={item.file} /><b>{item.file.name}</b><small>{item.file.size < 1024 ? `${item.file.size} Б` : `${(item.file.size / 1024).toFixed(1)} КБ`}</small></button><button className="file-remove" aria-label={`Удалить ${item.file.name}`} onClick={() => remove(item.id)}><X aria-hidden="true" size={12} /></button><a className="file-download" href={item.url} download={item.file.name} aria-label={`Скачать ${item.file.name}`} title="Забрать файл"><ArrowDownToLine aria-hidden="true" size={12} /></a></motion.div>)}</AnimatePresence></div> : <button className="shelf-empty" onClick={() => input.current?.click()}><span className="empty-file-icon"><Plus aria-hidden="true" size={25} strokeWidth={1} /></span><b>{magnet ? 'Отпустите. Я подхвачу.' : 'Место для ваших файлов'}</b><span>Перетащите сюда или выберите с Mac</span></button>}
          <div className="shelf-bottom"><span><i />{magnet ? 'Магнитное поле активно' : files.length ? 'Только на время этой сессии' : 'Без загрузки в облако'}</span>{files.length > 0 && <button onClick={() => input.current?.click()} aria-label="Добавить ещё файлы"><Plus aria-hidden="true" size={13} />Добавить</button>}</div>
        </motion.div>}</AnimatePresence></div>
      </motion.div>
      {magnet && <motion.div className="magnetic-field" initial={{ opacity: 0, scale: .8 }} animate={{ opacity: 1, scale: 1 }} exit={{ opacity: 0 }} aria-hidden="true"><i /><i /><i /></motion.div>}
      <AnimatePresence>{demo && <motion.div className="demo-drag-file" initial={{ x: 180, y: 300, opacity: 0, rotate: -12 }} animate={{ x: 128, y: 140, opacity: 1, rotate: -5 }} exit={{ scale: .3, y: 10, opacity: 0 }}><FileImage aria-hidden="true" size={28} /><span>Исследование.fig</span><MousePointer2 aria-hidden="true" className="demo-pointer" size={22} fill="#252722" /></motion.div>}</AnimatePresence>
      <div className="shelf-status" role="status" style={{ top: expanded ? (files.length ? 314 : 268) : 64 }}>{status || (expanded ? 'Нужное остаётся под рукой' : `${files.length} файлов внутри`)}</div>
    </div>
    <AnimatePresence>{preview && <motion.div className="preview-backdrop" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} onClick={() => setPreview(null)}><motion.section ref={previewRef} className="file-preview" role="dialog" aria-modal="true" aria-label={`Просмотр ${preview.file.name}`} initial={{ scale: .94, y: 12 }} animate={{ scale: 1, y: 0 }} onClick={e => e.stopPropagation()}><div className="preview-title"><FileText aria-hidden="true" size={16} /><b>{preview.file.name}</b><IconButton label="Закрыть просмотр" onClick={() => setPreview(null)}><X aria-hidden="true" size={17} /></IconButton></div><div className="preview-body">{preview.file.type.startsWith('image/') ? <img src={preview.url} alt={preview.file.name} /> : text ? <pre>{text}</pre> : <div className="generic-preview"><FileGlyph file={preview.file} /><p>Файл на вашей временной полке</p><small>{preview.file.type || 'Документ'} · {preview.file.size.toLocaleString('ru-RU')} Б</small></div>}</div><a className="preview-download" href={preview.url} download={preview.file.name}><ArrowDownToLine aria-hidden="true" size={15} />Сохранить на Mac</a></motion.section></motion.div>}</AnimatePresence>
  </>;
}

function Wallpaper() {
  return <svg className="wallpaper" viewBox="0 0 1440 680" preserveAspectRatio="xMidYMid slice" aria-hidden="true"><defs>
    <linearGradient id="wallbase" x1="0" y1="0" x2="1" y2="1"><stop stopColor="#c4c9ba"/><stop offset=".5" stopColor="#dce0d2"/><stop offset="1" stopColor="#e6e5dc"/></linearGradient>
    <linearGradient id="fold1" x1="0" y1="1" x2=".8" y2="0"><stop stopColor="#dfe2d5"/><stop offset=".40" stopColor="#bfc7b7"/><stop offset=".66" stopColor="#879782"/><stop offset=".82" stopColor="#657c66"/><stop offset=".93" stopColor="#b4c1ab"/><stop offset="1" stopColor="#eef0e4"/></linearGradient>
    <linearGradient id="fold2" x1="0" y1="1" x2="1" y2="0"><stop stopColor="#243d31"/><stop offset=".3" stopColor="#45624b"/><stop offset=".7" stopColor="#8d9f7d"/><stop offset=".94" stopColor="#d7ddc4"/><stop offset="1" stopColor="#f2f1df"/></linearGradient>
    <linearGradient id="fold3" x1="0" y1="1" x2="1" y2="0"><stop stopColor="#142e26"/><stop offset=".45" stopColor="#254d39"/><stop offset=".7" stopColor="#668265"/><stop offset=".93" stopColor="#a9bb94"/><stop offset="1" stopColor="#d5ddbd"/></linearGradient>
    <filter id="wall-grain"><feTurbulence type="fractalNoise" baseFrequency=".8" numOctaves="3" stitchTiles="stitch"/><feColorMatrix type="saturate" values="0"/><feComponentTransfer><feFuncA type="linear" slope=".045"/></feComponentTransfer><feBlend in="SourceGraphic" mode="multiply"/></filter>
  </defs><g filter="url(#wall-grain)"><rect width="1440" height="680" fill="url(#wallbase)"/><path d="M-100 560C160 390 100 580 470 560S960 530 1030 340 1210 10 1580 20V800H-100Z" fill="url(#fold1)"/><path d="M-180 710C110 290 380 770 780 580S880 280 1120 270 1240 450 1580 160V800H-180Z" fill="url(#fold2)"/><path d="M150 800C330 620 590 820 830 640S1010 230 1240 390 1470 300 1580 340V800Z" fill="url(#fold3)"/><path d="M710 800C850 660 980 650 1120 570s290 120 430-80V800Z" fill="#203e30" opacity=".6"/></g></svg>;
}
function Apple() { return <svg width="12" height="15" viewBox="0 0 14 17" fill="currentColor" aria-hidden="true"><path d="M10.8 8.7c0-1.5.8-2.2 1.5-2.7-.9-1.2-2.2-1.3-2.7-1.3-1.1 0-1.8.6-2.6.6s-1.4-.6-2.4-.6C2.9 4.7 1 6.2 1 9c0 1.7.6 3.5 1.4 4.7.7 1 1.3 1.7 2.2 1.7.8 0 1.2-.5 2.4-.5s1.5.5 2.4.5 1.5-.8 2.1-1.7c.5-.8.8-1.5 1-2.1-1.1-.5-1.7-1.5-1.7-2.9ZM9 3.3c.6-.7 1-1.6.9-2.5-1 .1-1.9.6-2.5 1.3S6.3 3.7 6.4 4.5c.9.1 1.9-.4 2.6-1.2Z" /></svg>; }

export default function App() {
  const [concept, setConcept] = useState<Concept>('liquid');
  const [shelfFiles, setShelfFiles] = useState<ShelfFile[]>([]);
  const shelfUrls = useRef(new Set<string>());
  const aboutRef = useRef<HTMLElement>(null);
  useEffect(() => { const saved = shelfUrls.current; return () => saved.forEach(url => URL.revokeObjectURL(url)); }, []);
  const [controls, setControls] = useState<ReactNode>(null);
  const [reset, setReset] = useState(0);
  const [slow, setSlow] = useState(false);
  const systemReduced = useReducedMotion();
  const [reducedOverride, setReducedOverride] = useState(false);
  const [focus, setFocus] = useState(false);
  const [help, setHelp] = useState(false);
  const reduced = Boolean(systemReduced || reducedOverride);
  useModalFocus(help, aboutRef);
  const active = concepts.find(c => c.id === concept)!;
  const sceneRef = useRef<HTMLDivElement>(null);
  const controlsCallback = useCallback((node: ReactNode) => setControls(node), []);
  useEscape(() => { if (help) setHelp(false); if (focus) setFocus(false); });
  const select = (id: Concept) => setConcept(id);
  useEffect(() => { const handler = (e: KeyboardEvent) => { if ((e.target as HTMLElement).matches('input,textarea,[contenteditable]') || document.querySelector('[role=dialog]') || e.metaKey || e.ctrlKey || e.altKey) return; if (['1', '2', '3'].includes(e.key)) select(concepts[Number(e.key) - 1].id); if (e.key.toLowerCase() === 'r' && !e.metaKey && !e.ctrlKey) setReset(r => r + 1); }; window.addEventListener('keydown', handler); return () => window.removeEventListener('keydown', handler); }, []);
  return <MotionConfig reducedMotion={reduced ? 'always' : 'never'} transition={reduced ? { duration: 0 } : { type: 'spring', stiffness: slow ? 110 : 340, damping: slow ? 23 : 31, mass: .9 }}>
    <main className={`lab ${focus ? 'focus-mode' : ''}`} data-reduced={reduced}>
      <header className="site-header"><a href="/" className="brand" aria-label="Чёлка — главная"><span className="brand-symbol"><i /></span><span>чёлка<span className="brand-dot">.</span></span></a><span className="header-project">MACOS NOTCH MOTION LAB<span>EXPLORATION / 001</span></span><div className="local-badge"><span />Локальный прототип <span className="version">v.01</span></div></header>
      <section className="intro"><div><div className="eyebrow"><span />МАЛЕНЬКИЙ ИНТЕРФЕЙС. БОЛЬШЕ ВОЗМОЖНОСТЕЙ.</div><h1>За пределами чёлки<span>.</span></h1><p>Три способа переосмыслить пространство вокруг камеры.</p></div><button className="about-button" onClick={() => setHelp(h => !h)} aria-expanded={help}>Об эксперименте<ArrowUpRight aria-hidden="true" size={16}/></button></section>
      <section className="workspace" aria-label="Лаборатория движения">
        <div className="workspace-toolbar"><div className="concept-tabs" role="tablist" aria-label="Концепции" onKeyDown={e => {
          if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(e.key)) return;
          e.preventDefault(); const current = concepts.findIndex(c => c.id === concept);
          const index = e.key === 'Home' ? 0 : e.key === 'End' ? 2 : (current + (e.key === 'ArrowRight' ? 1 : 2)) % 3;
          select(concepts[index].id); document.getElementById(`tab-${concepts[index].id}`)?.focus();
        }}>{concepts.map(c => <button id={`tab-${c.id}`} aria-controls="concept-scene" role="tab" aria-selected={concept === c.id} tabIndex={concept === c.id ? 0 : -1} key={c.id} onClick={() => select(c.id)} className={concept === c.id ? 'active' : ''}>{concept === c.id && <motion.span className="tab-highlight" layoutId="active-tab" />}<span className="tab-number">{c.number}</span><span className="tab-name">{c.name}</span></button>)}</div><div className="scene-tools"><span className="live-label"><i />LIVE PREVIEW</span><span className="divider" /><IconButton label="Повторить сцену" onClick={() => setReset(r => r + 1)}><RotateCcw aria-hidden="true" size={15} /></IconButton><IconButton label={focus ? 'Выйти из фокус-режима' : 'Фокус-режим'} onClick={() => setFocus(f => !f)}><Maximize2 aria-hidden="true" size={15} /></IconButton></div></div>
        <div className={`desktop concept-${concept}`} id="concept-scene" ref={sceneRef} role="tabpanel" aria-labelledby={`tab-${concept}`}>
          <Wallpaper />
          <div className="mac-menu"><div className="mac-menu-left"><Apple /><b>Finder</b><span>Файл</span><span>Правка</span><span>Вид</span><span>Переход</span></div><div className="mac-menu-right"><BatteryFull aria-hidden="true" size={17}/><Wifi aria-hidden="true" size={13}/><Settings2 aria-hidden="true" size={12}/><span>Вс, 8 ноя</span><span>09:41</span></div></div>
          <div className="desktop-caption"><span>ПРОСТРАНСТВО ДЛЯ ЭКСПЕРИМЕНТОВ</span><span>MacBook Pro <i>·</i> 16-inch</span></div>
          <AnimatePresence mode="wait"><motion.div key={`${concept}-${reset}`} className="concept-stage" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0, transition: { duration: reduced ? 0 : .15 } }}>{concept === 'liquid' ? <Liquid controls={controlsCallback} reduced={reduced} slow={slow} reset={reset} /> : concept === 'orbit' ? <Orbit controls={controlsCallback} reduced={reduced} slow={slow} reset={reset} /> : <Shelf controls={controlsCallback} reduced={reduced} slow={slow} reset={reset} files={shelfFiles} setFiles={setShelfFiles} urls={shelfUrls} />}</motion.div></AnimatePresence>
          <div className="scene-guidance" key={concept}><MousePointer2 aria-hidden="true" size={13}/><span>{active.cue}</span><span className="esc-tip"><Key>esc</Key> свернуть</span></div>
          <div className="desktop-dock" aria-hidden="true"><span className="dock-finder"><span>⌣</span></span><span className="dock-notes"><i/><i/><i/></span><span className="dock-music"><AudioLines aria-hidden="true" size={23}/></span><span className="dock-terminal">›_</span><i className="dock-divider"/><span className="dock-folder"><Folder aria-hidden="true" size={28} fill="#8eb3c2" stroke="#bed2db"/></span></div>
          <span className="scene-corner">DESKTOP SIMULATION</span>
        </div>
        <div className="experiment-footer"><div className="experiment-caption"><span className="experiment-number">{active.number}</span><div><h2>{active.name}<span>{active.tag}</span></h2><p>{active.description}</p></div></div><div className="concept-pagination"><button aria-label="Предыдущая концепция" onClick={() => select(concepts[(concepts.findIndex(c => c.id === concept) + 2) % 3].id)}><ArrowLeft aria-hidden="true" size={16}/></button><span>{active.number}<i>/</i>03</span><button aria-label="Следующая концепция" onClick={() => select(concepts[(concepts.findIndex(c => c.id === concept) + 1) % 3].id)}><ArrowRight aria-hidden="true" size={16}/></button></div></div>
      </section>
      <section className="control-panel" aria-label="Панель управления"><div className="control-panel-title"><Settings2 aria-hidden="true" size={15}/><span>Пульт эксперимента</span><span className="control-shortcut"><Key>R</Key> повторить</span></div><div className="control-panel-body"><div className="concept-controls">{controls}</div><div className="motion-controls"><div className="control-group"><SectionLabel>Движение</SectionLabel><div className="button-row"><button className={`toggle-button ${slow ? 'on' : ''}`} role="switch" aria-checked={slow} onClick={() => setSlow(v => !v)}><span className="toggle-track"><i/></span>Замедлить</button><button className={`reduced-button ${reduced ? 'on' : ''}`} aria-pressed={reduced} disabled={Boolean(systemReduced)} onClick={() => setReducedOverride(v => !v)} title={systemReduced ? 'Включено в системных настройках' : 'Уменьшить движение'}>{reduced ? <Check aria-hidden="true" size={13}/> : <span className="reduced-circle"/>}Меньше движения</button></div></div></div></div></section>
      <footer className="page-footer"><span>Сначала ощущение. Потом интерфейс.</span><span>Сделано для любопытства <span className="footer-spark">✳</span><span className="keyboard-hint"><Key>1</Key><Key>2</Key><Key>3</Key> переключить концепцию</span></span></footer>
      <AnimatePresence>{help && <motion.div className="about-backdrop" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} onClick={() => setHelp(false)}><motion.section ref={aboutRef} role="dialog" aria-modal="true" aria-label="Об эксперименте" className="about-modal" initial={{ y: 20, scale: .97 }} animate={{ y: 0, scale: 1 }} onClick={e => e.stopPropagation()}><div className="about-top"><span className="eyebrow">ЧЁЛКА / MOTION STUDIES</span><IconButton label="Закрыть описание" onClick={() => setHelp(false)}><X aria-hidden="true" size={18}/></IconButton></div><h2>Маленькая деталь.<br/>Большое поле для идей.</h2><p>Это лаборатория будущего приложения для Mac. Исследуем, как чёлка может становиться полезной частью рабочего пространства.</p><div className="about-concepts">{concepts.map(c => <button key={c.id} onClick={() => { select(c.id); setHelp(false); }}><span>{c.number}</span><b>{c.name}</b><small>{c.tag}</small><ArrowUpRight aria-hidden="true" size={16}/></button>)}</div><div className="about-note"><Key>1–3</Key> концепции <Key>R</Key> повтор <Key>esc</Key> свернуть</div><small className="about-limits">Музыка и события — симуляция. Файлы — настоящие, хранятся только в памяти вкладки. После перезагрузки или закрытия вкладки полка очистится.</small></motion.section></motion.div>}</AnimatePresence>
    </main>
  </MotionConfig>;
}
