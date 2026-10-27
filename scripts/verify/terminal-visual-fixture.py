#!/usr/bin/env python3
"""Deterministic screen and raw-key fixtures for the isolated SSH UI lab."""
import json
import os
import select
import sys
import termios
import tty
from pathlib import Path

if sys.argv[1:] == ['keys']:
    path = Path('/tmp/moshpit-ui-lab/key-events.json')
    fd = sys.stdin.fileno()
    original = termios.tcgetattr(fd)
    events = []
    print('KEY_READER_READY — Esc / arrows / Ctrl+C', flush=True)
    try:
        tty.setraw(fd)
        path.write_text(json.dumps(events))
        while True:
            ready, _, _ = select.select([fd], [], [], 30)
            if not ready:
                break
            chunk = os.read(fd, 4096)
            if not chunk:
                break
            events.extend(chunk)
            path.write_text(json.dumps(events))
            if 3 in chunk:
                break
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, original)
    print('\r\nKEY_READER_DONE', flush=True)
else:
    print('\033[2J\033[H', end='')
    print('\033[1;36miPad native terminal / 原生终端视觉检查\033[0m')
    print('中文、English、1234567890 — 等宽字体与段落')
    print('\033[31mRED 红色\033[0m  \033[32mGREEN 绿色\033[0m  \033[34mBLUE 蓝色\033[0m')
    print('\033[1mBOLD 粗体\033[0m  \033[3mItalic 斜体\033[0m  \033[4mUnderline 下划线\033[0m')
    print('')
    print('Code / 缩进与符号:')
    print('def greet(name):')
    print('    if name:')
    print('        return "Hello, " + name')
    print('')
    print('+------------------+------------+')
    print('| ITEM             | STATUS     |')
    print('+------------------+------------+')
    print('| keyboard         | READY      |')
    print('| sidebar          | READY      |')
    print('| native colours   | READY      |')
    print('+------------------+------------+')
    print('')
    for i in range(1, 13):
        print(f'{i:02d}  terminal row — 中文内容与 English text 保持原生布局')
    print('\033[36mVISUAL_FIXTURE_READY\033[0m', flush=True)
