"""Portable source regressions; intentionally not a headset acceptance gate."""
import argparse, hashlib, json, shutil, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ROOT_TESTS = ['frame_once_120', 'rse_optional_preview_120', 'gen1_stock_host_clouds',
 'gen2_compat', 'gen2_controls', 'gen2_lightning_profiles', 'gen2_lightning_bolt',
 'gen2_lightning_variety', 'gen2_storm_front', 'gen2_voxel_clouds',
 'gen2_weather_render', 'pc_packet_sky', 'quest_rain_speed']
PARTICLE_TESTS = ['precip_120', 'sand_120', 'snow_ground_120',
 'firefly_glow_120', 'firefly_habitat_120']

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--luajit', default=shutil.which('luajit'))
    ap.add_argument('--output', type=Path)
    args=ap.parse_args()
    assert args.luajit, 'LuaJIT is required; pass --luajit explicitly'
    results=[]
    def run(command):
        r=subprocess.run(command,cwd=ROOT,capture_output=True,text=True,timeout=60)
        results.append({'command':command,'exit':r.returncode,'output':r.stdout+r.stderr})
        print(r.stdout+r.stderr,end='')
        if r.returncode: raise RuntimeError('Source test failed: '+str(command))
    run([sys.executable,'tests/release_contract.py'])
    for name in ROOT_TESTS:
        run([args.luajit,'tests/'+name+'.lua','.'])
    for name in PARTICLE_TESTS:
        run([args.luajit,'tests/'+name+'.lua','lib/voxel_atmos'])
    for name in ['frame_once_120','rse_optional_preview_120']:
        run([args.luajit,'-joff','tests/'+name+'.lua','.'])
    files=sorted(p for folder in ['bootstrap','compat','lib','tests']
                 for p in (ROOT/folder).rglob('*.lua'))
    files += [ROOT/'main.lua', ROOT/'weather_main.lua']
    for start in range(0,len(files),65):
        run([args.luajit,'tests/syntax_120.lua',*[str(p.relative_to(ROOT)) for p in files[start:start+65]]])
    source={p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest()
            for p in files if 'tests' not in p.relative_to(ROOT).parts}
    report={'status':'PASS source/mock fixtures only','headsetAcceptance':'PENDING',
            'tests':results,'luaChunksCompiled':len(files),'luaSources':source}
    if args.output:
        args.output.parent.mkdir(parents=True,exist_ok=True)
        args.output.write_text(json.dumps(report,indent=2),encoding='utf-8')
    print('PASS source regressions; native/headset qualification is separate')

if __name__=='__main__': main()
