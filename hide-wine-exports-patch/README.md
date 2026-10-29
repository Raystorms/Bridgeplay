# hide-wine-exports-patch

Some games look up `wine_get_version` in ntdll and turn features off when it answers. The
Witcher 3 5.0 (`witcher3.exe`, `GetProcAddress(ntdll, "wine_get_version")`) then never calls
`slInit`, so NVIDIA Streamline loads no plugins and the game offers no DLSS, only FSR and XeSS.
Wine Staging hides these exports with `HideWineExports`; WineCX has no such switch.

`winecx-hide-wine-exports.patch` (against winecx `e0aa380`) adds a check to
`get_proc_address` in `dlls/kernel32/module.c` and `dlls/kernelbase/loader.c`: with
`NOTPROTON_HIDE_WINE_EXPORTS` set, a lookup by name of an ntdll export starting with `wine_`
(`wine_get_version`, `wine_get_build_id`, `wine_get_host_version`, `wine_server_call`, ...) fails
with `ERROR_PROC_NOT_FOUND`. `__wine_*` stays visible: winecrt0's `__wine_init_unix_call` looks
those up in every builtin, and hiding them stops D3DMetal's `dxgi.dll` from initializing. Other
modules are untouched (gdi32 and user32 look up `wine_` names in display drivers and imm32), and
so are lookups by ordinal,
`LdrGetProcedureAddress` and static imports. `compat_run.sh` sets the variable for the
`HIDE_WINE_EXPORTS=1` gamefix key.

Build in the tree from `winemac-patch/README.md` (mingw-w64 gcc 16.2,
`DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`):
`make dlls/kernel32/x86_64-windows/kernel32.dll dlls/kernelbase/x86_64-windows/kernelbase.dll`,
with each DLL's `.res` files made by the `make -n` lines with `--po-dir` pointed at an empty
folder (the runtime carries English resources only; with the tree's `po/` kernelbase grows by
1.6 MB), then `x86_64-w64-mingw32-strip --strip-debug`. `.rsrc` then matches the runtime's
byte for byte. Built without the patch, kernelbase's `.text` differs from the runtime's in 12
bytes only: offsets to the critical-section names, which carry the source path
(`../winecx-1117/` here, `../winecx/` in the CI). Pins: `FreeEngineWinecx.v1117.loader` and
`docs/WINECX.md`.
