# usage: python3 assemble.py <libv86.js> <v86.wasm> <seabios.bin> <vgabios.bin> <bzImage> <out.html>
import base64, gzip, sys
lib, wasm, bios, vga, kern, out = sys.argv[1:7]
b64 = lambda b: base64.b64encode(b).decode()
gz  = lambda p: b64(gzip.compress(open(p,'rb').read(), 9))
t = open('template.html').read()
l = open(lib).read(); assert '</script' not in l
t = t.replace('"/*__WASM__*/"','"'+gz(wasm)+'"').replace('"/*__BIOS__*/"','"'+gz(bios)+'"')
t = t.replace('"/*__VGA__*/"','"'+gz(vga)+'"').replace('"/*__KERNEL__*/"','"'+b64(open(kern,'rb').read())+'"')
t = t.replace('/*__LIBV86__*/', l)
open(out,'w').write(t); print('wrote', out, len(t)//1024, 'KB')
