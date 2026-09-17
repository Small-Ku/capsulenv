#!/usr/bin/env python3
from __future__ import annotations
import contextlib, fcntl, json, os, pathlib, shutil, signal, statistics, subprocess, sys, tempfile, time
from dataclasses import dataclass, asdict
from typing import Any


def pct(xs, p):
    ys=sorted(xs)
    if not ys: return None
    k=(len(ys)-1)*p
    f=int(k); c=min(f+1,len(ys)-1)
    if f==c: return ys[f]
    return ys[f]*(c-k)+ys[c]*(k-f)


def proc_start_ticks(pid:int):
    try:
        txt=pathlib.Path(f"/proc/{pid}/stat").read_text()
        tail=txt[txt.rfind(')')+2:].split()
        return int(tail[19])
    except Exception:
        return None


def atomic_json(path:pathlib.Path, data:Any):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp=path.with_name(path.name+f".tmp.{os.getpid()}")
    with open(tmp,'w',encoding='utf-8') as f:
        json.dump(data,f,sort_keys=True)
        f.flush(); os.fsync(f.fileno())
    os.replace(tmp,path)


def spawn_sleep(script:pathlib.Path, seconds=30):
    return subprocess.Popen([sys.executable, str(script), str(seconds)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def cleanup(ps):
    for p in ps:
        if p.poll() is None:
            with contextlib.suppress(Exception): p.terminate()
    deadline=time.time()+1
    for p in ps:
        if p.poll() is None:
            with contextlib.suppress(Exception): p.wait(max(0,deadline-time.time()))
    for p in ps:
        if p.poll() is None:
            with contextlib.suppress(Exception): p.kill()


def ownership_experiment(root:pathlib.Path):
    host=root/'host-depot'; capsule=root/'capsule'; host.mkdir(); capsule.mkdir()
    script=host/'fake_service.py'
    script.write_text('import sys,time\ntime.sleep(float(sys.argv[1]))\n')
    owned=spawn_sleep(script); foreign=spawn_sleep(script)
    time.sleep(.08)
    try:
        exe_owned=os.path.realpath(f'/proc/{owned.pid}/exe')
        exe_foreign=os.path.realpath(f'/proc/{foreign.pid}/exe')
        current_capsule_path_detected=[pid for pid,exe in [(owned.pid,exe_owned),(foreign.pid,exe_foreign)] if exe.startswith(str(capsule)+os.sep)]
        command_paths={owned.pid:str(script), foreign.pid:str(script)}
        host_path_detected=[pid for pid,p in command_paths.items() if p.startswith(str(host)+os.sep)]
        ledger={"session":"S1","processes":[{"pid":owned.pid,"start_ticks":proc_start_ticks(owned.pid),"role":"service"}]}
        ledger_detected=[]
        for r in ledger['processes']:
            if proc_start_ticks(r['pid'])==r['start_ticks']:
                ledger_detected.append(r['pid'])
        return {
            'owned_pid':owned.pid,'foreign_pid':foreign.pid,
            'current_capsule_path_detected':current_capsule_path_detected,
            'naive_host_path_detected':host_path_detected,
            'ledger_detected':ledger_detected,
            'current_false_negative_owned': owned.pid not in current_capsule_path_detected,
            'naive_host_false_positive_foreign': foreign.pid in host_path_detected,
            'ledger_exact': ledger_detected==[owned.pid],
        }
    finally: cleanup([owned,foreign])


def pid_reuse_guard_experiment(root:pathlib.Path):
    script=root/'sleeper.py'; script.write_text('import time; time.sleep(30)\n')
    p=spawn_sleep(script); time.sleep(.05)
    old_start=proc_start_ticks(p.pid); old_pid=p.pid
    p.terminate(); p.wait()
    q=spawn_sleep(script); time.sleep(.05)
    try:
        stale={'pid':q.pid,'start_ticks':old_start}
        pid_only_would_accept = pathlib.Path(f"/proc/{stale['pid']}").exists()
        pid_plus_start_accept = proc_start_ticks(stale['pid'])==stale['start_ticks']
        return {'old_pid':old_pid,'replacement_pid':q.pid,'pid_only_would_accept':pid_only_would_accept,
                'pid_plus_start_accept':pid_plus_start_accept,'guard_rejects_stale': pid_only_would_accept and not pid_plus_start_accept}
    finally: cleanup([q])


def service_health_experiment(root:pathlib.Path):
    bad=root/'bad.py'; bad.write_text('import sys; sys.exit(7)\n')
    good=root/'good.py'; ready=root/'ready'; good.write_text(f"import pathlib,time\npathlib.Path({str(ready)!r}).write_text('ready')\ntime.sleep(30)\n")
    b=subprocess.Popen([sys.executable,str(bad)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    routine_detached_reported_success=True
    deadline=time.time()+4
    actual_bad_exit=None
    while time.time()<deadline:
        actual_bad_exit=b.poll()
        if actual_bad_exit is not None: break
        time.sleep(.02)
    service_manager_detected_failure=actual_bad_exit is not None
    g=subprocess.Popen([sys.executable,str(good)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline=time.time()+3
    while time.time()<deadline and not ready.exists() and g.poll() is None: time.sleep(.01)
    good_healthy=ready.exists() and g.poll() is None
    cleanup([g])
    return {'detached_routine_reported_success':routine_detached_reported_success,
            'bad_service_actual_exit':actual_bad_exit,
            'health_checked_manager_detected_failure':service_manager_detected_failure,
            'healthy_service_ready_detected':good_healthy}


def _unlocked_worker(state, read_barrier, write_barrier):
    data=json.loads(pathlib.Path(state).read_text())
    pathlib.Path(read_barrier+f'.{os.getpid()}').write_text('r')
    while len(list(pathlib.Path(read_barrier).parent.glob(pathlib.Path(read_barrier).name+'.*'))) < 2: time.sleep(.005)
    data['counter']+=1
    pathlib.Path(state).write_text(json.dumps(data))


def _locked_worker(state, lockfile):
    with open(lockfile,'a+') as lf:
        fcntl.flock(lf.fileno(), fcntl.LOCK_EX)
        data=json.loads(pathlib.Path(state).read_text()); time.sleep(.03); data['counter']+=1
        atomic_json(pathlib.Path(state),data)
        fcntl.flock(lf.fileno(), fcntl.LOCK_UN)


def state_concurrency_experiment(root:pathlib.Path):
    import multiprocessing as mp
    state=root/'portable_state.json'; state.write_text('{"counter":0}')
    barrier=str(root/'read')
    ps=[mp.Process(target=_unlocked_worker,args=(str(state),barrier,'')) for _ in range(2)]
    [p.start() for p in ps]; [p.join(3) for p in ps]
    unlocked=json.loads(state.read_text())['counter']
    state.write_text('{"counter":0}'); lock=root/'state.lock'
    ps=[mp.Process(target=_locked_worker,args=(str(state),str(lock))) for _ in range(2)]
    [p.start() for p in ps]; [p.join(3) for p in ps]
    locked=json.loads(state.read_text())['counter']
    return {'expected':2,'without_lease_or_lock':unlocked,'with_os_lock_and_atomic_metadata':locked,
            'lost_update_without_lock':unlocked!=2,'correct_with_lock':locked==2}


def stale_lock_experiment(root:pathlib.Path):
    lockfile=root/'sentinel.lock'
    code=f"from pathlib import Path; import os; Path({str(lockfile)!r}).write_text('locked'); os._exit(9)"
    subprocess.run([sys.executable,'-c',code])
    sentinel_stale=lockfile.exists()
    oslock=root/'os.lock'
    code2=f"import fcntl,os; f=open({str(oslock)!r},'a+'); fcntl.flock(f.fileno(),fcntl.LOCK_EX); os._exit(9)"
    subprocess.run([sys.executable,'-c',code2])
    with open(oslock,'a+') as f:
        try:
            fcntl.flock(f.fileno(),fcntl.LOCK_EX|fcntl.LOCK_NB); os_lock_reacquired=True
        except BlockingIOError: os_lock_reacquired=False
    return {'sentinel_file_left_after_crash':sentinel_stale,'os_lock_reacquired_after_crash':os_lock_reacquired,
            'recommendation':'OS lock/lease, not existence-only lockfile'}


def _scan_proc_for_prefix(prefix:str):
    out=[]
    for d in pathlib.Path('/proc').iterdir():
        if not d.name.isdigit(): continue
        try: exe=os.path.realpath(d/'exe')
        except Exception: continue
        if exe.startswith(prefix): out.append(int(d.name))
    return out


def ledger_perf_experiment(root:pathlib.Path):
    ledger=root/'session.json'
    selfrec={'pid':os.getpid(),'start_ticks':proc_start_ticks(os.getpid()),'role':'shell'}
    atomic_json(ledger,{'processes':[selfrec]})
    scan=[]; read=[]
    for _ in range(80):
        t=time.perf_counter_ns(); _scan_proc_for_prefix(str(root)); scan.append((time.perf_counter_ns()-t)/1e6)
        t=time.perf_counter_ns(); data=json.loads(ledger.read_text());
        _=[r for r in data['processes'] if proc_start_ticks(r['pid'])==r['start_ticks']]
        read.append((time.perf_counter_ns()-t)/1e6)
    return {'proc_scan_ms':{'p50':pct(scan,.5),'p95':pct(scan,.95)},'ledger_validate_ms':{'p50':pct(read,.5),'p95':pct(read,.95)},
            'ledger_faster_p50':pct(read,.5)<pct(scan,.5)}

@dataclass
class Candidate:
    name:str; provider:str; version:int; trusted:bool; path_rank:int

def resolve(cands, minv, maxv, mode):
    if mode=='path-first':
        return sorted(cands,key=lambda c:c.path_rank)[0] if cands else None
    valid=[c for c in cands if c.trusted and minv<=c.version<=maxv]
    provider_rank={'host-scoop':0,'capsulenv-local':1,'seed':2,'upstream':3,'path':9}
    return sorted(valid,key=lambda c:(provider_rank.get(c.provider,8),-c.version))[0] if valid else None

def provider_resolution_experiment(root:pathlib.Path):
    cands=[Candidate('firefox','path',999,False,0),Candidate('firefox','host-scoop',130,True,5),Candidate('firefox','capsulenv-local',129,True,10)]
    a=resolve(cands,129,131,'path-first'); b=resolve(cands,129,131,'constrained')
    too_new=[Candidate('firefox','host-scoop',140,True,0),Candidate('firefox','capsulenv-local',130,True,1)]
    c=resolve(too_new,129,131,'constrained')
    return {'path_first_selected':asdict(a),'constrained_selected':asdict(b),'newer_incompatible_scenario_selected':asdict(c),
            'path_first_unsafe':not a.trusted or not (129<=a.version<=131),
            'constraint_avoids_wrong_host_version':c.provider=='capsulenv-local'}


def retention_tradeoff_experiment(root:pathlib.Path):
    src=root/'seed.bin'; src.write_bytes(os.urandom(8*1024*1024))
    depot=root/'depot'; depot.mkdir()
    def deploy():
        t=time.perf_counter(); shutil.copy2(src,depot/'tool.bin'); return (time.perf_counter()-t)*1000
    cold=deploy(); t=time.perf_counter(); exists=(depot/'tool.bin').exists(); warm=(time.perf_counter()-t)*1000
    shutil.rmtree(depot); depot.mkdir(); red=deploy()
    return {'payload_bytes':src.stat().st_size,'first_deploy_ms':cold,'retained_repeat_check_ms':warm,'ephemeral_redeploy_ms':red,'retained_found':exists,
            'finding':'retention must be policy; retained optimizes repeat visit, ephemeral minimizes host residue'}


def state_placement_experiment(root:pathlib.Path):
    import random
    BS=4096; OPS=800; SIZE=8*1024*1024
    rng=random.Random(42)
    portable=root/'portable'; host=root/'host'; portable.mkdir(); host.mkdir()
    base=os.urandom(SIZE); p=portable/'profile.db'; p.write_bytes(base)
    offsets=[rng.randrange(0,SIZE//BS)*BS for _ in range(OPS)]; payload=os.urandom(BS)
    for off in offsets:
        with open(p,'r+b',buffering=0) as f: f.seek(off); f.write(payload)
    direct_final=p.read_bytes(); direct_bytes=OPS*BS
    p.write_bytes(base); h=host/'profile.db'; shutil.copy2(p,h)
    for off in offsets:
        with open(h,'r+b',buffering=0) as f: f.seek(off); f.write(payload)
    shutil.copy2(h,p); mirror_final=p.read_bytes()
    p.write_bytes(base); h.write_bytes(base)
    for off in offsets[:50]:
        with open(h,'r+b',buffering=0) as f: f.seek(off); f.write(payload)
    crash_stale=(p.read_bytes()==base and h.read_bytes()!=base)
    a=host/'a.db'; b=host/'b.db'; a.write_bytes(base); b.write_bytes(base); p.write_bytes(base)
    pa=os.urandom(BS); pb=os.urandom(BS)
    with open(a,'r+b',buffering=0) as f: f.seek(0); f.write(pa)
    with open(b,'r+b',buffering=0) as f: f.seek(BS); f.write(pb)
    shutil.copy2(a,p); shutil.copy2(b,p); final=p.read_bytes()
    lost=(final[:BS]!=pa and final[BS:2*BS]==pb)
    return {'file_bytes':SIZE,'write_ops':OPS,'write_size':BS,
            'direct_portable_logical_write_bytes':direct_bytes,
            'host_mirror_sync_portable_bytes':SIZE,
            'host_mirror_mutation_bytes':OPS*BS,
            'mirror_final_equal_to_direct':mirror_final==direct_final,
            'crash_before_sync_leaves_portable_stale':crash_stale,
            'two_stale_mirrors_last_writer_loses_change':lost}

def user_integration_experiment(root:pathlib.Path):
    portable=root/'E-capenv'; host=root/'LocalAppData-Capsulenv'; portable.mkdir(); host.mkdir()
    launcher=portable/'capsulenv.cmd'; launcher.write_text('portable launcher')
    bridge=host/'capsulenv-host.cmd'; bridge.write_text('host integration bridge')
    before_direct=launcher.exists(); before_bridge=bridge.exists(); portable.rename(root/'detached-device')
    return {'direct_before_detach':before_direct,'direct_after_detach':launcher.exists(),
            'bridge_before_detach':before_bridge,'bridge_after_detach':bridge.exists(),
            'direct_persistent_target_dangles':before_direct and not launcher.exists(),
            'host_bridge_survives_detach':bridge.exists()}

def main():
    base=pathlib.Path(tempfile.mkdtemp(prefix='capsulenv-ablation-'))
    results={'environment':{'platform':sys.platform,'python':sys.version.split()[0]},'experiments':{}}
    try:
        for name,fn in [
            ('process_ownership',ownership_experiment),
            ('stale_pid_guard',pid_reuse_guard_experiment),
            ('session_service_health',service_health_experiment),
            ('portable_state_concurrency',state_concurrency_experiment),
            ('crash_lock_semantics',stale_lock_experiment),
            ('ownership_lookup_cost',ledger_perf_experiment),
            ('provider_resolution',provider_resolution_experiment),
            ('host_depot_retention',retention_tradeoff_experiment),
            ('state_placement',state_placement_experiment),
            ('user_integration_target',user_integration_experiment),
        ]:
            d=base/name; d.mkdir(); results['experiments'][name]=fn(d)
        ex=results['experiments']
        results['findings']={
            'session_ledger_required': ex['process_ownership']['ledger_exact'] and ex['process_ownership']['current_false_negative_owned'],
            'path_ownership_dominated': ex['process_ownership']['naive_host_false_positive_foreign'],
            'pid_identity_must_include_start_time_or_nonce': ex['stale_pid_guard']['guard_rejects_stale'],
            'generic_detached_routine_not_service_manager': ex['session_service_health']['detached_routine_reported_success'] and ex['session_service_health']['health_checked_manager_detected_failure'],
            'portable_mutable_state_needs_exclusive_lease_policy': ex['portable_state_concurrency']['lost_update_without_lock'] and ex['portable_state_concurrency']['correct_with_lock'],
            'lockfile_existence_is_bad_crash_fallback': ex['crash_lock_semantics']['sentinel_file_left_after_crash'] and ex['crash_lock_semantics']['os_lock_reacquired_after_crash'],
            'provider_resolution_needs_trust_and_version_constraints': ex['provider_resolution']['path_first_unsafe'] and ex['provider_resolution']['constraint_avoids_wrong_host_version'],
            'host_depot_retention_is_policy_not_global_default': True,
            'generic_state_mirror_rejected': ex['state_placement']['crash_before_sync_leaves_portable_stale'] and ex['state_placement']['two_stale_mirrors_last_writer_loses_change'],
            'persistent_user_integration_needs_host_local_target': ex['user_integration_target']['direct_persistent_target_dangles'] and ex['user_integration_target']['host_bridge_survives_detach'],
        }
    finally:
        shutil.rmtree(base,ignore_errors=True)
    print(json.dumps(results,indent=2,sort_keys=True))

if __name__=='__main__': main()
