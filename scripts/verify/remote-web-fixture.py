#!/usr/bin/env python3
"""Owned loopback HTTP + WebSocket origin for SSH web-preview verification.
No user folders, credentials or sessions are read. Stop its own PID after testing.
"""
import argparse
import base64
import hashlib
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import os
import struct
import threading
import time

class Origin(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *_): pass
    def reply(self, body, kind='text/plain; charset=utf-8', status=200, **headers):
        if isinstance(body, str): body = body.encode()
        self.send_response(status)
        self.send_header('Content-Type', kind)
        self.send_header('Content-Length', str(len(body)))
        for k, v in headers.items(): self.send_header(k.replace('_', '-'), v)
        self.end_headers()
        try: self.wfile.write(body); self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError): pass
    def do_GET(self):
        path = self.path.split('?')[0]
        if path == '/ws': return self.websocket()
        if path == '/large': return self.reply(bytes(range(256))*8192, 'application/octet-stream')
        if path == '/asset.js': return self.reply("document.getElementById('asset').textContent='资源已加载';fetch('/echo',{method:'POST',body:'synthetic-post'}).then(r=>r.text()).then(t=>document.getElementById('post').textContent=t);const ws=new WebSocket('ws://'+location.host+'/ws');ws.onopen=()=>ws.send('WebSocket 已连接');ws.onmessage=e=>document.getElementById('socket').textContent=e.data;", 'application/javascript')
        if path == '/redirect': return self.reply('', status=302, Location=f'http://localhost:{self.server.server_port}/final')
        if path == '/final': return self.reply('<h1>重定向成功</h1>', 'text/html; charset=utf-8')
        if path == '/events':
            self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.send_header('Connection','close'); self.end_headers()
            for i in range(4):
                try: self.wfile.write(f'data: {i}\n\n'.encode()); self.wfile.flush(); time.sleep(.03)
                except (BrokenPipeError,ConnectionResetError): break
            self.close_connection = True
            return
        if path == '/hold':
            self.send_response(200); self.send_header('Content-Length',str(64*1024*1024)); self.end_headers()
            for _ in range(4096):
                try: self.wfile.write(b'x'*16384); self.wfile.flush(); time.sleep(.01)
                except (BrokenPipeError,ConnectionResetError): break
            self.close_connection = True
            return
        self.reply('<!doctype html><meta name="viewport" content="width=device-width"><title>Hermit 远端预览</title><style>body{font:18px -apple-system;padding:24px;background:#f5f7fa;color:#20252d}article{padding:20px;background:white;border-radius:16px}a{display:block;margin:20px 0}</style><h1>Hermit 远端预览</h1><article><p id="asset">载入资源…</p><p id="post">等待 POST</p><p id="socket">等待 WebSocket</p><a href="/redirect">测试远端重定向</a></article><script src="/asset.js"></script>', 'text/html; charset=utf-8')
    def do_POST(self):
        length = int(self.headers.get('Content-Length',0))
        if length > 4*1024*1024: return self.reply('too large', status=413)
        self.reply(self.rfile.read(length), 'application/octet-stream')
    def websocket(self):
        key = self.headers.get('Sec-WebSocket-Key','')
        accept = base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        self.send_response(101); self.send_header('Upgrade','websocket'); self.send_header('Connection','Upgrade'); self.send_header('Sec-WebSocket-Accept',accept); self.end_headers()
        try:
            while True:
                header = self.rfile.read(2)
                if len(header) < 2: return
                opcode = header[0]&15; size = header[1]&127
                if size == 126: size = struct.unpack('!H', self.rfile.read(2))[0]
                elif size == 127: size = struct.unpack('!Q', self.rfile.read(8))[0]
                if size > 4*1024*1024: return
                mask = self.rfile.read(4) if header[1]&128 else b''
                data = self.rfile.read(size)
                if len(data) != size: return
                if mask: data = bytes(v^mask[i%4] for i,v in enumerate(data))
                if opcode == 8: return
                if opcode == 9: opcode = 10
                frame = bytes([0x80|opcode])
                frame += bytes([len(data)]) if len(data)<126 else b'\x7e'+struct.pack('!H',len(data)) if len(data)<65536 else b'\x7f'+struct.pack('!Q',len(data))
                self.wfile.write(frame+data); self.wfile.flush()
        except (OSError,ValueError): pass
        finally: self.close_connection = True

if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__); parser.add_argument('--state',type=Path,required=True); args=parser.parse_args()
    if args.state.exists(): raise SystemExit('Use a new state file')
    server=ThreadingHTTPServer(('127.0.0.1',0),Origin); server.daemon_threads=True
    args.state.write_text(json.dumps({'pid':os.getpid(),'port':server.server_port}))
    args.state.chmod(0o600)
    server.serve_forever()
