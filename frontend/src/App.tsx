import { useState, useEffect, useRef } from 'react';
import './App.css';

// Predefined ASCII Drawings from AmethystOS data_commands.asm
const drawGem = `    /\\  \r
   /  \\ \r
  / /\\ \\\r
 /_/  \\_\\\r
 \\ \\  / /\r
  \\ \\/ / \r
   \\  /  \r
    \\/   Amethyst\r\n`;

const drawCat = ` /\\_/\\ \r
( o.o )\r
 > ^ < \r\n`;

const drawLogo = `   _              _   _               _   \r
  /_\\  _ __  ___ | |_| |__ _  _ ___ _| |_ \r
 / _ \\| '  \\/ -_)|  _| '_ \\ || (_-<  _  |\r
/_/ \\_\\_|_|_\\___| \\__|_.__/\\_, /__/\\____|\r
                           |__/           \r\n`;

function App() {

  // OS Boot states: 'bios' | 'running' | 'halted' | 'shutdown'
  const [bootState, setBootState] = useState<'bios' | 'running' | 'halted' | 'shutdown'>('bios');
  
  // CLI State
  const [cmdBuffer, setCmdBuffer] = useState<string>('');
  const [history, setHistory] = useState<string[]>([]);
  const [historyIndex, setHistoryIndex] = useState<number>(0);
  const [mouseCell, setMouseCell] = useState<{ x: number; y: number }>({ x: 0, y: 0 });
  const [renderToken, setRenderToken] = useState<number>(0);

  // References for system state
  const memoryRef = useRef<Uint8Array>(new Uint8Array(0x100000)); // 1MB RAM
  const cursorRef = useRef<number>(0); // byte position in VGA screen space relative to 0xB8000
  const textAttrRef = useRef<number>(0x0F); // current text color attribute (white on black)
  const lineStartPosRef = useRef<number>(0); // byte index where input starts on the current line
  const timeoutsRef = useRef<number[]>([]);
  const screenRef = useRef<HTMLDivElement>(null);
  const bootTimeRef = useRef<number>(Date.now());

  // Scrollback history refs
  const scrollOffsetRef = useRef<number>(0);
  const histWriteRef = useRef<number>(0);
  const histCountRef = useRef<number>(0);
  const HIST_ROWS = 256;
  const historyBufferRef = useRef<Uint8Array[]>([]);
  const liveShadowRef = useRef<Uint8Array>(new Uint8Array(4000));

  const triggerRender = () => setRenderToken(prev => prev + 1);

  // Initialize simulated memory with BDA, Boot sector, and ACPI tables
  const initMemory = (mem: Uint8Array) => {
    // 1. IVT (0x0000 - 0x03FF)
    for (let i = 0; i < 0x400; i += 4) {
      mem[i] = Math.floor(Math.random() * 256);
      mem[i+1] = 0x00;
      mem[i+2] = Math.floor(Math.random() * 256);
      mem[i+3] = 0xF0;
    }

    // 2. BDA (0x0400 - 0x04FF)
    mem[0x410] = 0x26; // Equipment list
    mem[0x413] = 0x80; // memory size
    mem[0x414] = 0x02;

    // 3. Boot Sector (0x7C00 - 0x7DFF)
    mem[0x7C00] = 0xEB; // JMP short
    mem[0x7C01] = 0x3C;
    mem[0x7C02] = 0x90; // NOP
    const label = "AMETHYSTOS BOOT";
    for (let i = 0; i < label.length; i++) {
      mem[0x7C03 + i] = label.charCodeAt(i);
    }
    mem[0x7C00 + 510] = 0x55;
    mem[0x7C00 + 511] = 0xAA; // Boot signature

    // 4. ACPI RSDP (0x000F5AD0)
    const rsdpSig = "RSD PTR ";
    for (let i = 0; i < rsdpSig.length; i++) {
      mem[0x000F5AD0 + i] = rsdpSig.charCodeAt(i);
    }
    mem[0x000F5AD8] = 0x2E; // Checksum
    mem[0x000F5ADF] = 2; // Revision 2.0 (XSDT)

    // 5. VGA Text mode memory (0xB8000 - 0xB8FA0)
    const attr = textAttrRef.current;
    for (let i = 0; i < 4000; i += 2) {
      mem[0xB8000 + i] = 32; // character space
      mem[0xB8000 + i + 1] = attr; // attribute byte
    }
  };



  // Boot sequence: matches real AOS - blank screen then instant "Hello, Amethyst!"
  const runBootSequence = () => {
    setBootState('bios');
    const mem = memoryRef.current;
    initMemory(mem);
    cursorRef.current = 0;
    lineStartPosRef.current = 0;
    textAttrRef.current = 0x0F;
    triggerRender();

    // Brief blank screen (simulating POST/memory init), then instant shell
    const t = window.setTimeout(() => {
      setBootState('running');
      histWriteRef.current = 0;
      histCountRef.current = 0;
      scrollOffsetRef.current = 0;
      historyBufferRef.current = [];
      clearVgaScreen();
      printString("Hello, Amethyst!\n");
      printString("> ");
      lineStartPosRef.current = cursorRef.current;
      bootTimeRef.current = Date.now();
      focusScreen();
    }, 400);
    timeoutsRef.current.push(t);
  };

  const skipBoot = () => {
    timeoutsRef.current.forEach(clearTimeout);
    timeoutsRef.current = [];
    setBootState('running');
    histWriteRef.current = 0;
    histCountRef.current = 0;
    scrollOffsetRef.current = 0;
    historyBufferRef.current = [];
    clearVgaScreen();
    printString("Hello, Amethyst!\n");
    printString("> ");
    lineStartPosRef.current = cursorRef.current;
    bootTimeRef.current = Date.now();
    focusScreen();
  };

  // Run boot sequence on mount
  useEffect(() => {
    runBootSequence();
    return () => {
      timeoutsRef.current.forEach(clearTimeout);
    };
  }, []);

  const focusScreen = () => {
    if (screenRef.current) {
      screenRef.current.focus();
    }
  };

  // Text display writing methods
  const printChar = (char: string, attr: number = textAttrRef.current) => {
    snapScrollToLive();
    const mem = memoryRef.current;
    let cursor = cursorRef.current;

    if (char === '\n') {
      const row = Math.floor(cursor / 160);
      cursorRef.current = (row + 1) * 160;
    } else if (char === '\b') {
      if (cursor > lineStartPosRef.current) {
        cursor -= 2;
        mem[0xB8000 + cursor] = 32;
        mem[0xB8000 + cursor + 1] = attr;
        cursorRef.current = cursor;
      }
    } else {
      mem[0xB8000 + cursor] = char.charCodeAt(0);
      mem[0xB8000 + cursor + 1] = attr;
      cursorRef.current = cursor + 2;
    }

    // Screen wrapping and scrolling
    if (cursorRef.current >= 4000) {
      scrollScreen();
      cursorRef.current = 3840; // cursor placed at start of bottom row
    }
  };

  const printString = (str: string, attr: number = textAttrRef.current) => {
    // Normalize newlines: convert all \r\n and \r to \n
    const normalized = str.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
    for (let i = 0; i < normalized.length; i++) {
      printChar(normalized[i], attr);
    }
    triggerRender();
  };

  const scrollScreen = () => {
    const mem = memoryRef.current;

    // Save row 0 (about to scroll off) into historyBuffer
    const row0 = new Uint8Array(160);
    for (let i = 0; i < 160; i++) {
      row0[i] = mem[0xB8000 + i];
    }
    historyBufferRef.current[histWriteRef.current % HIST_ROWS] = row0;
    histWriteRef.current += 1;
    if (histCountRef.current < HIST_ROWS) {
      histCountRef.current += 1;
    }

    // Copy rows 1..24 to 0..23
    const rowBytes = mem.subarray(0xB8000 + 160, 0xB8000 + 4000);
    mem.set(rowBytes, 0xB8000);
    
    // Clear row 24
    const attr = textAttrRef.current;
    for (let i = 3840; i < 4000; i += 2) {
      mem[0xB8000 + i] = 32;
      mem[0xB8000 + i + 1] = attr;
    }
  };

  const saveLiveShadow = () => {
    const mem = memoryRef.current;
    const shadow = liveShadowRef.current;
    for (let i = 0; i < 4000; i++) {
      shadow[i] = mem[0xB8000 + i];
    }
  };

  const restoreLiveShadow = () => {
    const mem = memoryRef.current;
    const shadow = liveShadowRef.current;
    for (let i = 0; i < 4000; i++) {
      mem[0xB8000 + i] = shadow[i];
    }
  };

  const snapScrollToLive = () => {
    if (scrollOffsetRef.current > 0) {
      scrollOffsetRef.current = 0;
      restoreLiveShadow();
      triggerRender();
    }
  };

  const repaintScrolledView = () => {
    const mem = memoryRef.current;
    const offset = scrollOffsetRef.current;
    const shadow = liveShadowRef.current;
    const buffer = historyBufferRef.current;
    const count = histCountRef.current;
    const write = histWriteRef.current;

    for (let row = 0; row < 25; row++) {
      if (row < offset) {
        // Render from history: rowsBack = offset - row - 1
        const rowsBack = offset - row - 1;
        if (rowsBack < count) {
          const absIdx = (write - 1 - rowsBack + HIST_ROWS * 2) % HIST_ROWS;
          const histRow = buffer[absIdx];
          if (histRow) {
            mem.set(histRow, 0xB8000 + row * 160);
          } else {
            blankRow(row);
          }
        } else {
          blankRow(row);
        }
      } else {
        // Copy the corresponding row from live shadow (liveRow = row - offset)
        const liveRow = row - offset;
        const start = liveRow * 160;
        const rowBytes = shadow.subarray(start, start + 160);
        mem.set(rowBytes, 0xB8000 + row * 160);
      }
    }
    triggerRender();
  };

  const blankRow = (row: number) => {
    const mem = memoryRef.current;
    const attr = textAttrRef.current;
    for (let col = 0; col < 80; col++) {
      mem[0xB8000 + row * 160 + col * 2] = 32;
      mem[0xB8000 + row * 160 + col * 2 + 1] = attr;
    }
  };

  const scrollViewUp = () => {
    if (scrollOffsetRef.current < histCountRef.current) {
      if (scrollOffsetRef.current === 0) {
        saveLiveShadow();
      }
      scrollOffsetRef.current += 1;
      repaintScrolledView();
    }
  };

  const scrollViewDown = () => {
    if (scrollOffsetRef.current > 0) {
      scrollOffsetRef.current -= 1;
      if (scrollOffsetRef.current === 0) {
        restoreLiveShadow();
        triggerRender();
      } else {
        repaintScrolledView();
      }
    }
  };

  const clearVgaScreen = () => {
    snapScrollToLive();
    const mem = memoryRef.current;
    const attr = textAttrRef.current;
    for (let i = 0; i < 4000; i += 2) {
      mem[0xB8000 + i] = 32;
      mem[0xB8000 + i + 1] = attr;
    }
    cursorRef.current = 0;
    triggerRender();
  };

  // Input redraw method to support arrows, backspaces and inserts
  const redrawInput = (newCmd: string, newCursorOffset: number) => {
    const mem = memoryRef.current;
    const start = lineStartPosRef.current;
    const attr = textAttrRef.current;

    // Clear input space on this row
    const rowEnd = Math.floor(start / 160) * 160 + 160;
    const maxLen = rowEnd - start;
    for (let i = 0; i < maxLen; i += 2) {
      mem[0xB8000 + start + i] = 32;
      mem[0xB8000 + start + i + 1] = attr;
    }

    // Write new command string
    for (let i = 0; i < newCmd.length; i++) {
      mem[0xB8000 + start + i * 2] = newCmd.charCodeAt(i);
      mem[0xB8000 + start + i * 2 + 1] = attr;
    }

    cursorRef.current = start + newCursorOffset * 2;
    triggerRender();
  };



  // Commands dispatch logic
  const executeCommand = (cmdStr: string) => {
    const trimmed = cmdStr.trim();
    if (!trimmed) return;

    const tokens = trimmed.split(/\s+/);
    const cmd = tokens[0].toLowerCase();
    const args = tokens.slice(1);

    const restricted = ['run', 'mem', 'peek', 'poke', 'cpuid', 'acpi', 'sysinfo', 'cursor', 'reboot', 'halt', 'shutdown'];
    if (restricted.includes(cmd)) {
      printString("This command is only available on the real AOS.\r\n");
      return;
    }

    switch (cmd) {
      case 'help':
        printString("AmethystOS Commands:\r\n");
        printString("help          - list available commands\r\n");
        printString("echo          - print the given text\r\n");
        printString("draw          - show a fun ASCII drawing: draw [gem|cat|amethyst_text]\r\n");
        printString("calc          - basic arithmetic: calc <a> <+|-|*|/|%|sqrt> [b]\r\n");
        printString("clear         - clear the screen\r\n");
        printString("color         - set text color: color <red|green|blue|yellow|white|HH>\r\n");
        printString("date          - show the current date\r\n");
        printString("time          - show the current time\r\n");
        printString("uptime        - show system uptime\r\n");
        break;

      case 'echo':
        // Pure print without trailing newline, matching assembly cmd_echo
        printString(args.join(' '));
        break;

      case 'clear':
        clearVgaScreen();
        break;

      case 'uptime':
        const seconds = Math.floor((Date.now() - bootTimeRef.current) / 1000);
        printString(`${seconds} s\r\n`);
        break;

      case 'date':
        const d = new Date();
        printString(`${String(d.getDate()).padStart(2, '0')}/${String(d.getMonth()+1).padStart(2, '0')}/${d.getFullYear()}\r\n`);
        break;

      case 'time':
        const t = new Date();
        printString(`${String(t.getHours()).padStart(2, '0')}:${String(t.getMinutes()).padStart(2, '0')}:${String(t.getSeconds()).padStart(2, '0')}\r\n`);
        break;

      case 'calc':
        handleCalc(args);
        break;

      case 'color':
        handleColor(args);
        break;

      case 'draw':
        handleDraw(args);
        break;

      default:
        printString(`Unknown command: ${tokens[0]}\r\n`);
        break;
    }
  };

  // Command handlers
  const handleCalc = (args: string[]) => {
    // Check for prefix sqrt: "calc sqrt <a>"
    if (args.length === 2 && args[0].toLowerCase() === 'sqrt') {
      const val = parseInt(args[1], 10);
      if (isNaN(val)) {
        printString("Usage: calc <a> <+|-|*|/|%|sqrt> [b]\r\n");
      } else if (val < 0) {
        printString("Cannot take sqrt of a negative number\r\n");
      } else {
        printString(`${Math.floor(Math.sqrt(val))}\r\n`);
      }
      return;
    }

    // Check for suffix sqrt: "calc <a> sqrt"
    if (args.length === 2 && args[1].toLowerCase() === 'sqrt') {
      const val = parseInt(args[0], 10);
      if (isNaN(val)) {
        printString("Usage: calc <a> <+|-|*|/|%|sqrt> [b]\r\n");
      } else if (val < 0) {
        printString("Cannot take sqrt of a negative number\r\n");
      } else {
        printString(`${Math.floor(Math.sqrt(val))}\r\n`);
      }
      return;
    }

    // Binary operations: "calc <a> <op> <b>"
    if (args.length === 3) {
      const a = parseInt(args[0], 10);
      const op = args[1];
      const b = parseInt(args[2], 10);

      if (isNaN(a) || isNaN(b)) {
        printString("Usage: calc <a> <+|-|*|/|%|sqrt> [b]\r\n");
        return;
      }

      switch (op) {
        case '+': printString(`${a + b}\r\n`); break;
        case '-': printString(`${a - b}\r\n`); break;
        case '*': printString(`${a * b}\r\n`); break;
        case '/':
          if (b === 0) printString("Division by zero\r\n");
          else printString(`${Math.floor(a / b)}\r\n`);
          break;
        case '%':
          if (b === 0) printString("Division by zero\r\n");
          else printString(`${a % b}\r\n`);
          break;
        default:
          printString("Usage: calc <a> <+|-|*|/|%|sqrt> [b]\r\n");
      }
      return;
    }

    printString("Usage: calc <a> <+|-|*|/|%|sqrt> [b]\r\n");
  };









  const handleColor = (args: string[]) => {
    if (args.length < 1) {
      printString("Usage: color <red|green|blue|yellow|white|HH>\r\n");
      return;
    }

    const val = args[0].toLowerCase();
    let attr = 0x0F;

    if (val === 'red') attr = 0x04;
    else if (val === 'green') attr = 0x02;
    else if (val === 'blue') attr = 0x01;
    else if (val === 'yellow') attr = 0x0E;
    else if (val === 'white') attr = 0x0F;
    else {
      // Try hex byte e.g. "0F"
      const hex = parseInt(val, 16);
      if (!isNaN(hex) && hex >= 0 && hex <= 255) {
        attr = hex;
      } else {
        printString("Usage: color <red|green|blue|yellow|white|HH>\r\n");
        return;
      }
    }

    // Set new attribute and recolor all existing cells (matching recolor_screen)
    textAttrRef.current = attr;
    const mem = memoryRef.current;
    for (let i = 1; i < 4000; i += 2) {
      mem[0xB8000 + i] = attr;
    }
    triggerRender();
  };

  const handleDraw = (args: string[]) => {
    if (args.length < 1) {
      printString("Usage: draw <gem|cat|amethyst_text>\r\n");
      return;
    }

    const val = args[0].toLowerCase();
    if (val === 'gem') printString(drawGem);
    else if (val === 'cat') printString(drawCat);
    else if (val === 'amethyst_text') printString(drawLogo);
    else printString("Usage: draw <gem|cat|amethyst_text>\r\n");
  };





  const triggerReboot = () => {
    timeoutsRef.current.forEach(clearTimeout);
    timeoutsRef.current = [];
    setBootState('bios');
    setCmdBuffer('');
    setHistoryIndex(0);
    histWriteRef.current = 0;
    histCountRef.current = 0;
    scrollOffsetRef.current = 0;
    historyBufferRef.current = [];
    runBootSequence();
  };



  // Keyboard events listener
  const handleKeyDown = (e: React.KeyboardEvent<HTMLDivElement>) => {
    // If powered off/shutdown, any key press boots the system back up!
    if (bootState === 'shutdown') {
      e.preventDefault();
      triggerReboot();
      return;
    }
    
    if (bootState === 'halted') {
      e.preventDefault();
      return;
    }

    if (bootState === 'bios') {
      if (e.key === ' ' || e.key === 'Enter') {
        e.preventDefault();
        skipBoot();
      }
      return;
    }

    if (e.key === 'Tab') {
      e.preventDefault();
      return;
    }

    // Scroll snaps back to live when any input occurs
    if (!e.shiftKey || (e.key !== 'ArrowUp' && e.key !== 'ArrowDown')) {
      snapScrollToLive();
    }

    const cursorOffset = (cursorRef.current - lineStartPosRef.current) / 2;

    if (e.key === 'ArrowLeft') {
      e.preventDefault();
      if (cursorOffset > 0) {
        redrawInput(cmdBuffer, cursorOffset - 1);
      }
    } else if (e.key === 'ArrowRight') {
      e.preventDefault();
      if (cursorOffset < cmdBuffer.length) {
        redrawInput(cmdBuffer, cursorOffset + 1);
      }
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      if (e.shiftKey) {
        scrollViewUp();
      } else {
        if (history.length > 0) {
          const nextIdx = historyIndex + 1;
          if (nextIdx <= history.length) {
            setHistoryIndex(nextIdx);
            const histCmd = history[history.length - nextIdx];
            redrawInput(histCmd, histCmd.length);
            setCmdBuffer(histCmd);
          }
        }
      }
    } else if (e.key === 'ArrowDown') {
      e.preventDefault();
      if (e.shiftKey) {
        scrollViewDown();
      } else {
        if (historyIndex > 1) {
          const nextIdx = historyIndex - 1;
          setHistoryIndex(nextIdx);
          const histCmd = history[history.length - nextIdx];
          redrawInput(histCmd, histCmd.length);
          setCmdBuffer(histCmd);
        } else if (historyIndex === 1) {
          setHistoryIndex(0);
          redrawInput('', 0);
          setCmdBuffer('');
        }
      }
    } else if (e.key === 'Backspace') {
      e.preventDefault();
      if (cursorOffset > 0) {
        const newCmd = cmdBuffer.slice(0, cursorOffset - 1) + cmdBuffer.slice(cursorOffset);
        setCmdBuffer(newCmd);
        redrawInput(newCmd, cursorOffset - 1);
      }
    } else if (e.key === 'Delete') {
      e.preventDefault();
      if (cursorOffset < cmdBuffer.length) {
        const newCmd = cmdBuffer.slice(0, cursorOffset) + cmdBuffer.slice(cursorOffset + 1);
        setCmdBuffer(newCmd);
        redrawInput(newCmd, cursorOffset);
      }
    } else if (e.key === 'Enter') {
      e.preventDefault();
      printString('\n');
      const prevCmd = cmdBuffer;
      executeCommand(cmdBuffer);
      
      if (cmdBuffer.trim()) {
        setHistory(prev => {
          const next = [...prev];
          if (next.length === 0 || next[next.length - 1] !== cmdBuffer) {
            next.push(cmdBuffer);
          }
          return next;
        });
      }
      
      setCmdBuffer('');
      setHistoryIndex(0);
      
      // Print trailing newline (newline_only) and new prompt
      if (bootState === 'running') {
        const isClear = prevCmd.trim().toLowerCase() === 'clear';
        if (!isClear) {
          printString('\n'); // Matches .newline_only in process_command
        }
        printString('> ');
        lineStartPosRef.current = cursorRef.current;
      }
    } else if (e.key.length === 1 && !e.ctrlKey && !e.metaKey && !e.altKey) {
      e.preventDefault();
      const newCmd = cmdBuffer.slice(0, cursorOffset) + e.key + cmdBuffer.slice(cursorOffset);
      setCmdBuffer(newCmd);
      redrawInput(newCmd, cursorOffset + 1);
    }
  };

  // Mouse hover tracking
  const handleMouseMove = (e: React.MouseEvent<HTMLDivElement>) => {
    if (bootState !== 'running') return;
    const rect = e.currentTarget.getBoundingClientRect();
    const xVal = e.clientX - rect.left;
    const yVal = e.clientY - rect.top;

    const col = Math.floor((xVal / rect.width) * 80);
    const row = Math.floor((yVal / rect.height) * 25);

    const clampedCol = Math.max(0, Math.min(79, col));
    const clampedRow = Math.max(0, Math.min(24, row));

    if (clampedCol !== mouseCell.x || clampedRow !== mouseCell.y) {
      setMouseCell({ x: clampedCol, y: clampedRow });
    }
  };

  // Generate character chunks grouped by matching text attributes for rendering
  interface TextChunk {
    text: string;
    fg: number;
    bg: number;
    isCursor?: boolean;
  }

  const getRowChunks = (row: number): TextChunk[] => {
    const mem = memoryRef.current;
    const rowStart = 0xB8000 + row * 160;
    const chunks: TextChunk[] = [];
    
    let currentText = '';
    let currentFg = -1;
    let currentBg = -1;

    for (let col = 0; col < 80; col++) {
      const charByte = mem[rowStart + col * 2];
      const attrByte = mem[rowStart + col * 2 + 1];
      const char = charByte === 0 ? ' ' : String.fromCharCode(charByte);

      let fg = attrByte & 0x0F;
      let bg = (attrByte & 0xF0) >> 4;

      // Mouse cell cursor highlighting
      const isMouseOver = false;
      if (isMouseOver) {
        fg = 0;
        bg = 15;
      }

      // Blinking text cursor highlighting
      const isCursor = (scrollOffsetRef.current === 0) && (cursorRef.current === row * 160 + col * 2) && (bootState === 'running' || bootState === 'bios');

      if (isCursor) {
        if (currentText) {
          chunks.push({ text: currentText, fg: currentFg, bg: currentBg });
          currentText = '';
        }
        chunks.push({ text: char, fg, bg, isCursor: true });
        currentFg = -1;
        currentBg = -1;
      } else {
        if (currentText === '') {
          currentText = char;
          currentFg = fg;
          currentBg = bg;
        } else if (fg === currentFg && bg === currentBg) {
          currentText += char;
        } else {
          chunks.push({ text: currentText, fg: currentFg, bg: currentBg });
          currentText = char;
          currentFg = fg;
          currentBg = bg;
        }
      }
    }

    if (currentText) {
      chunks.push({ text: currentText, fg: currentFg, bg: currentBg });
    }

    return chunks;
  };

  // Generate rows array (0 to 24)
  const rows = Array.from({ length: 25 }, (_, i) => i);

  return (
    <div 
      ref={screenRef}
      id="terminal-screen"
      className="terminal-container"
      tabIndex={0}
      onKeyDown={handleKeyDown}
      onMouseMove={handleMouseMove}
      onClick={focusScreen}
    >
      <div key={renderToken} className="terminal-screen">
        {bootState !== 'shutdown' && rows.map((row) => (
          <div key={row} className="crt-row">
            {getRowChunks(row).map((chunk, idx) => (
              <span
                key={idx}
                className={`fg-${chunk.fg} bg-${chunk.bg} ${chunk.isCursor ? 'vga-cursor' : ''}`}
              >
                {chunk.text}
              </span>
            ))}
          </div>
        ))}
      </div>
    </div>
  );
}

export default App;
