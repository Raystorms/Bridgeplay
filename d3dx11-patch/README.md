# d3dx11-patch

`winecx-create-thread-pump.patch` turns `D3DX11CreateThreadPump` in `d3dx11_43` and `d3dx11_42`
from a spec stub into a function that returns `E_NOTIMPL`. A game that imports it (Persona 4
Golden, Discussion #170) otherwise dies at the first call with
`unimplemented function d3dx11_43.dll.D3DX11CreateThreadPump` (Wine bug 56176). The change is
upstream MR 6654 (closed, not merged): the `async.c` function, both `.spec` entries and the
prototype in `include/d3dx11core.idl`. winecx's `d3dx11_42.spec` forwards to `d3dx11_43` with
`-import`, so its entry does too, and both DLLs ship together. Wine master still has the stub
(checked 2026-10-22). Against winecx `e0aa380`; the build and pins are in `docs/WINECX.md`
(D3DX11 thread pump).
