# June-only candidate activation; reviewed exact baseline required.
import copy
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
import sys

D = '/nix/store/3fi6vs0wr2qzmlwxpnlkjdg96fzcpnpw-docker-29.6.0/bin/docker'
UNIT = 'convex-june-prod.service'
NAME = 'convex-june-prod-backend-1'
ROOT = Path('/var/lib/client-data/june-runtime-fc6f1b18')
DROP = Path('/etc/systemd/system.control/convex-june-prod.service.d/96-june-runtime-fc6f1b18.conf')
CAP = Path('/etc/systemd/system.control/convex-june-prod.service.d/90-june-capacity-936258ad.conf')
OLD_DROP = Path('/etc/systemd/system.control/convex-june-prod.service.d/95-june-timeout800-ba2d1bc.conf')
OLD_OVERLAY = Path('/var/lib/client-data/june-timeout800-ba2d1bc-attempt2/timeout.json')
TARGET = 'ghcr.io/nicolaischmid/june-convex-backend@sha256:fc6f1b18d8e4ed81b9f77dffe131bc58c333c85557f51501324418fd6a2eb2bb'
TARGET_ID = 'sha256:3109a3fa67890843b147771d480eea8106af011cae79084b3c330153c35aba5b'
BASE = [D, 'compose', '-p', 'convex-june-prod', '--project-directory', '/var/lib/client-data/convex/june-prod', '-f', '/nix/store/q6xiraiqj9dj7dgqjbm16n1d16fsyy8q-compose.yaml', '--env-file', '/nix/store/mpslx9raprzhqxs5ism0r68aayfmr5v8-convex-june-prod.env', '-f', '/nix/store/8bl5samc3z9qday7mvddkch2cxclfh9i-june-prod-capacity.json']
BASE += ['-f', str(OLD_OVERLAY)]
OVERLAY = ROOT / 'runtime.json'
NEW = BASE + ['-f', str(OVERLAY)]
UP = ['up', '-d', '--wait', '--no-deps', '--pull', 'never', 'backend']
HOST_DEFAULTS = {'ContainerIDFile': '', 'AutoRemove': False, 'VolumeDriver': '', 'VolumesFrom': None, 'ConsoleSize': [0, 0], 'CapAdd': None, 'CapDrop': None, 'CgroupnsMode': 'private', 'Dns': None, 'DnsOptions': None, 'DnsSearch': None, 'GroupAdd': None, 'IpcMode': 'private', 'Cgroup': '', 'Links': None, 'PidMode': '', 'Privileged': False, 'PublishAllPorts': False, 'ReadonlyRootfs': False, 'SecurityOpt': None, 'UTSMode': '', 'UsernsMode': '', 'ShmSize': 67108864, 'Runtime': 'runc', 'Isolation': '', 'CpuShares': 0, 'BlkioWeight': 0, 'BlkioWeightDevice': None, 'BlkioDeviceReadBps': None, 'BlkioDeviceWriteBps': None, 'BlkioDeviceReadIOps': None, 'BlkioDeviceWriteIOps': None, 'CpuPeriod': 0, 'CpuQuota': 0, 'CpuRealtimePeriod': 0, 'CpuRealtimeRuntime': 0, 'CpusetCpus': '', 'CpusetMems': '', 'Devices': None, 'DeviceCgroupRules': None, 'DeviceRequests': None, 'MemoryReservation': 0, 'MemorySwappiness': None, 'OomKillDisable': None, 'Ulimits': None, 'CpuCount': 0, 'CpuPercent': 0, 'IOMaximumIOps': 0, 'IOMaximumBandwidth': 0, 'MaskedPaths': ['/proc/acpi', '/proc/asound', '/proc/interrupts', '/proc/kcore', '/proc/keys', '/proc/latency_stats', '/proc/sched_debug', '/proc/scsi', '/proc/timer_list', '/proc/timer_stats', '/sys/devices/virtual/powercap', '/sys/firmware'], 'ReadonlyPaths': ['/proc/bus', '/proc/fs', '/proc/irq', '/proc/sys', '/proc/sysrq-trigger']}
EXPECTED_ID = 'e1eaf98ce2d55284d058cf914a3c08f22324d13cf74e29518f32a7bdbf60a263'

def require(condition, message):
    if not condition:
        raise RuntimeError(message)

def run(args, input=None):
    # Capture all output: Compose/inspect can contain credentials.
    p = subprocess.run(args, input=input, capture_output=True)
    if p.returncode:
        raise RuntimeError('command failed (output withheld): ' + args[0])
    return p.stdout

def config(args, input=None):
    return json.loads(run(args + ['config', '--format', 'json'], input))

def containers():
    ids = run([D, 'ps', '-aq']).decode().split()
    return json.loads(run([D, 'inspect'] + ids))

def routes():
    return {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
            for directory in ['/var/lib/client-data/traefik-dynamic', '/var/lib/client-data/routes/state']
            for p in Path(directory).glob('*') if p.is_file()}

def env(c):
    return dict(s.split('=', 1) for s in c['Config']['Env'])

def invariant(c):
    cfg = {k: v for k, v in c['Config'].items() if k not in ['Env', 'Hostname', 'Labels']}
    cfg['Labels'] = {k: v for k, v in c['Config']['Labels'].items() if k not in ['com.docker.compose.config-hash', 'com.docker.compose.project.config_files', 'com.docker.compose.replace']}
    return {k: c[k] for k in ['Image', 'Mounts', 'HostConfig']} | {
        'config': cfg,
        'networks': {k: {x: v[x] for x in ['Aliases', 'IPAMConfig', 'Links', 'DriverOpts']} for k, v in c['NetworkSettings']['Networks'].items()}}

def snapshot(allow_missing=False, old=None):
    cs = containers()
    june = next((c for c in cs if c['Name'] == '/' + NAME), None)
    require(allow_missing or june is not None, 'June container absent')
    renamed = [c for c in cs if old is not None and c['Id'] == old['Id'] and c['Name'] != '/' + NAME]
    for c in renamed:
        require(invariant(c) == invariant(old) and env(c) == env(old), 'renamed original June settings drift')
    return {'june': june, 'renamed': renamed, 'others': {c['Name']: [c['Id'], c['State']['StartedAt'] if ('backend' in c['Name'] or c['Name'] in ['/routes-api-1','/traefik-traefik-1']) else None] for c in cs if c != june and c not in renamed}, 'routes': routes(), 'cap': CAP.read_text(), 'old_drop': OLD_DROP.read_text(), 'old_overlay': OLD_OVERLAY.read_text(), 'config': config(BASE), 'unit': unit_state()}

def unit_state():
    result = {}
    for key in ['ExecStart', 'ExecReload', 'ExecStop']:
        value = run(['systemctl', 'show', UNIT, '-p', key, '--value']).decode()
        commands = re.findall(r'argv\[\]=(.*?) ; ignore_errors=', value)
        require(len(commands) == 1, 'unexpected unit command count')
        result[key] = commands[0]
    for key in ['Requires', 'After', 'DropInPaths', 'FragmentPath', 'Type', 'RemainAfterExit', 'User', 'Group']:
        result[key] = run(['systemctl', 'show', UNIT, '-p', key, '--value']).decode().strip()
    for key in ['Requires', 'After']:
        result[key] = ' '.join(sorted(result[key].split()))
    return result

def fingerprint(s):
    # Stable, nonsecret digest: omit health timestamps and runtime counters.
    stable = {k: s[k] for k in ['others', 'routes', 'cap', 'old_drop', 'old_overlay', 'config', 'unit']}
    stable.update(id=s['june']['Id'], runtime=invariant(s['june']), env=env(s['june']), state={k:s['june']['State'][k] for k in ['StartedAt','Running','Status']}, health=s['june']['State']['Health']['Status'])
    return hashlib.sha256(json.dumps(stable, sort_keys=True).encode()).hexdigest()

def reconcile(s):
    # Every key present in this exact base service must have an explicit mapping.
    c = s['june']; b = s['config']['services']['backend']; h = c['HostConfig']; cfg = c['Config']
    require(set(b) == {'cgroup_parent','command','cpus','entrypoint','environment','extra_hosts','healthcheck','image','labels','logging','mem_limit','memswap_limit','networks','oom_score_adj','pids_limit','ports','restart','stop_grace_period','stop_signal','volumes'}, 'unexpected base service fields')
    image = json.loads(run([D, 'image', 'inspect', b['image']]))[0]
    require({k:v for k,v in h.items() if k in HOST_DEFAULTS} == HOST_DEFAULTS and set(h) == set(HOST_DEFAULTS) | set(['CgroupParent', 'Memory', 'MemorySwap', 'PidsLimit', 'OomScoreAdj', 'NanoCpus', 'ExtraHosts', 'LogConfig', 'RestartPolicy', 'PortBindings', 'Binds', 'NetworkMode']), 'undeclared HostConfig settings differ from reviewed Docker defaults')
    require(image['Id'] == c['Image'] and cfg['Image'] == b['image'], 'image drift')
    require(cfg['User'] == image['Config'].get('User', '') and cfg['WorkingDir'] == image['Config'].get('WorkingDir', ''), 'image user/workdir drift')
    expected_env = dict(x.split('=', 1) for x in image['Config']['Env']); expected_env.update(b['environment'])
    require(expected_env == env(c), 'base/runtime environment drift')
    require(b['command'] == cfg['Cmd'] and (b['entrypoint'] if b['entrypoint'] is not None else image['Config']['Entrypoint']) == cfg['Entrypoint'], 'command drift')
    for k, hostkey in [('cgroup_parent','CgroupParent'),('mem_limit','Memory'),('memswap_limit','MemorySwap'),('pids_limit','PidsLimit'),('oom_score_adj','OomScoreAdj')]:
        require((b[k] if k == 'cgroup_parent' else int(b[k])) == h[hostkey], 'resource drift: ' + k)
    require(int(b['cpus'] * 1000000000) == h['NanoCpus'], 'CPU drift')
    require([v.replace('=', ':', 1) for v in b['extra_hosts']] == h['ExtraHosts'], 'host mapping drift')
    require({'Type': b['logging']['driver'], 'Config': b['logging']['options']} == h['LogConfig'], 'logging drift')
    require({'Name': b['restart'], 'MaximumRetryCount': 0} == h['RestartPolicy'], 'restart policy drift')
    ports = {}
    for port in b['ports']:
        require(port['mode'] == 'ingress', 'unexpected port mode')
        ports.setdefault(str(port['target']) + '/' + port['protocol'], []).append({'HostIp': port['host_ip'], 'HostPort': port['published']})
    require(ports == h['PortBindings'], 'port drift')
    require(b['volumes'] == [{'type':'bind','source':'/var/lib/client-data/convex/june-prod','target':'/convex/data','bind':{}}], 'base mount drift')
    require(h['Binds'] == ['/var/lib/client-data/convex/june-prod:/convex/data:rw'], 'bind options drift')
    require(c['Mounts'] == [{'Type':'bind','Source':'/var/lib/client-data/convex/june-prod','Destination':'/convex/data','Mode':'rw','RW':True,'Propagation':'rprivate'}], 'runtime mount/options/propagation drift')
    netnames = {s['config']['networks'][k]['name'] for k in b['networks']}
    require(netnames == set(c['NetworkSettings']['Networks']), 'network drift')
    require(h['NetworkMode'] == 'convex-june-prod_default', 'primary network drift')
    generated = {
        'com.docker.compose.container-number':'1', 'com.docker.compose.depends_on':'',
        'com.docker.compose.image':image['Id'], 'com.docker.compose.oneoff':'False',
        'com.docker.compose.project':'convex-june-prod', 'com.docker.compose.service':'backend',
        'com.docker.compose.project.config_files':','.join(BASE[i+1] for i,x in enumerate(BASE) if x == '-f'),
        'com.docker.compose.project.environment_file':BASE[BASE.index('--env-file')+1],
        'com.docker.compose.project.working_dir':'/var/lib/client-data/convex/june-prod',
        'com.docker.compose.version':run([D,'compose','version','--short']).decode().strip(),
    }
    labels = dict(image['Config'].get('Labels') or {}); labels.update(b['labels']); labels.update(generated)
    require({k:v for k,v in cfg['Labels'].items() if k not in ['com.docker.compose.config-hash','com.docker.compose.replace']} == labels, 'extra or changed labels')
    require(re.fullmatch('[0-9a-f]{64}',cfg['Labels'].get('com.docker.compose.config-hash','')) is not None, 'invalid Compose config hash')
    require(cfg['Labels'].get('com.docker.compose.replace') == 'backend-1', 'unexpected recreation metadata')
    for v in c['NetworkSettings']['Networks'].values():
        require(v['Aliases'] == [NAME,'backend'] and v['IPAMConfig'] is None and v['Links'] is None and v['DriverOpts'] is None, 'extra network settings')
    require(all(v is None for v in b['networks'].values()), 'base network options changed')
    require(b['healthcheck'] == {'test':['CMD-SHELL','curl -f http://localhost:3210/version'],'interval':'5s','start_period':'10s'}, 'base healthcheck drift')
    require(cfg['Healthcheck'] == {'Test':b['healthcheck']['test'],'Interval':5000000000,'StartPeriod':10000000000}, 'runtime healthcheck drift')
    require(b['stop_grace_period'] == '10s' and cfg['StopTimeout'] == 10 and b['stop_signal'] == cfg['StopSignal'] == 'SIGINT', 'stop behavior drift')

def proposed(s):
    overlay = json.dumps({'services': {'backend': {'image': TARGET, 'environment': {'NODE_ACTION_USER_TIMEOUT_SECS': '1800', 'HTTP_SERVER_TIMEOUT_SECONDS': '2100'}}}}).encode()
    expected = copy.deepcopy(s['config'])
    expected['services']['backend']['image'] = TARGET
    expected['services']['backend']['environment'].update(NODE_ACTION_USER_TIMEOUT_SECS='1800', HTTP_SERVER_TIMEOUT_SECONDS='2100')
    require(config(BASE + ['-f', '-'], overlay) == expected, 'resolved configuration differs beyond image and two timeouts')
    return overlay, expected

def preflight():
    require(not DROP.exists() and not ROOT.exists(), 'existing activation artifacts')
    s = snapshot()
    require(s['june']['Id'] == EXPECTED_ID, 'baseline container changed')
    require(s['june']['State']['Running'] and s['june']['State']['Status'] == 'running' and s['june']['State']['Health']['Status'] == 'healthy', 'unhealthy/stopped baseline')
    require(env(s['june']).get('NODE_ACTION_USER_TIMEOUT_SECS') == '800', 'action baseline drift')
    require(env(s['june'])['HTTP_SERVER_TIMEOUT_SECONDS'] == '1800', 'HTTP timeout drift')
    for key in ['ExecStart', 'ExecReload']:
        require(s['unit'][key] == ' '.join(BASE + UP), 'managed command drift')
    require(s['unit']['ExecStop'] == ' '.join(BASE[:-2] + ['down']), 'managed stop command drift')
    require(s['unit']['DropInPaths'] == str(CAP) + ' ' + str(OLD_DROP), 'unexpected unit drop-ins')
    reconcile(s)
    candidate = json.loads(run([D, 'image', 'inspect', TARGET]))[0]
    original = json.loads(run([D, 'image', 'inspect', s['config']['services']['backend']['image']]))[0]
    require(candidate['Id'] == TARGET_ID, 'candidate config ID mismatch')
    require({k:v for k,v in candidate['Config'].items() if k != 'Labels'} == {k:v for k,v in original['Config'].items() if k != 'Labels'}, 'candidate image defaults differ')
    overlay, expected = proposed(s)
    return s, overlay, expected

def expected_runtime(before, activated):
    result = invariant(before['june'])
    if activated:
        result['Image'] = TARGET_ID
        result['config']['Image'] = TARGET
        original = json.loads(run([D, 'image', 'inspect', before['june']['Image']]))[0]
        candidate = json.loads(run([D, 'image', 'inspect', TARGET]))[0]
        labels = result['config']['Labels']
        for key in (original['Config'].get('Labels') or {}):
            labels.pop(key, None)
        labels.update(candidate['Config'].get('Labels') or {})
        labels.update(before['config']['services']['backend']['labels'])
        labels['com.docker.compose.image'] = TARGET_ID
    return result


def expected_env(before, activated):
    result = env(before['june'])
    if activated:
        result.update(NODE_ACTION_USER_TIMEOUT_SECS='1800', HTTP_SERVER_TIMEOUT_SECONDS='2100')
    return result


def verify(before, activated):
    after = snapshot()
    require(after['others'] == before['others'], 'other containers changed')
    require(after['routes'] == before['routes'], 'routing drift')
    for key in ['cap', 'old_drop', 'old_overlay', 'config']:
        require(after[key] == before[key], 'baseline file/config drift: ' + key)
    require(invariant(after['june']) == expected_runtime(before, activated), 'runtime settings drift')
    require(env(after['june']) == expected_env(before, activated), 'environment drift')
    require(after['june']['State']['Running'] and after['june']['State']['Status'] == 'running' and after['june']['State']['Health']['Status'] == 'healthy', 'unhealthy/stopped backend')
    print(json.dumps({'id':after['june']['Id'], 'StartedAt':after['june']['State']['StartedAt'], 'running':True, 'healthy':True, 'imageID':after['june']['Image'], 'actionTimeout':env(after['june'])['NODE_ACTION_USER_TIMEOUT_SECS'], 'httpTimeout':env(after['june'])['HTTP_SERVER_TIMEOUT_SECONDS'], 'preservation':'PASS', 'privateRollback':str(ROOT)}))


def dropin_text():
    command = ' '.join(NEW + UP)
    return chr(10).join(['[Service]', 'ExecStart=', 'ExecStart=' + command,
                         'ExecReload=', 'ExecReload=' + command, ''])


def activated_unit(before):
    result = dict(before['unit'])
    result.update(ExecStart=' '.join(NEW + UP), ExecReload=' '.join(NEW + UP),
                  DropInPaths=before['unit']['DropInPaths'] + ' ' + str(DROP))
    return result


def stage(value):
    (ROOT / 'stage').write_text(value)

def main(action):
    os.umask(0o077)
    if action in ['check', 'apply']:
        before, overlay, expected = preflight()
        pin = fingerprint(before)
        if action == 'check':
            print('Read-only reconciliation and image/two-timeout Compose diff passed. Baseline SHA256: ' + pin)
            return
        require(len(sys.argv) == 3 and sys.argv[2] == pin, 'reviewed baseline fingerprint required; abort on drift')
        ROOT.mkdir(mode=0o700)
        (ROOT / 'before.json').write_text(json.dumps(before))
        stage('snapshot-saved')
        OVERLAY.write_bytes(overlay)
        require(config(NEW) == expected, 'persistent overlay differs')
        text = dropin_text()
        (ROOT / 'dropin').write_text(text)
        require(fingerprint(snapshot()) == pin, 'drift immediately before installing drop-in')
        temp = DROP.with_suffix('.pending')
        require(not temp.exists(), 'pending drop-in already exists')
        with temp.open('x') as f:
            f.write(text); f.flush(); os.fsync(f.fileno())
        os.replace(temp, DROP)
        stage('dropin-installed')
        run(['systemctl', 'daemon-reload'])
        loaded = unit_state()
        expected_unit = activated_unit(before)
        require(loaded == expected_unit, 'loaded unit differs')
        now = snapshot(); now['unit'] = before['unit']
        require(fingerprint(now) == pin, 'drift immediately before reload')
        stage('reload-starting')
        run(['systemctl', 'reload', UNIT])
        stage('reload-returned')
        verify(before, True)
        stage('verified')
    elif action == 'rollback':
        require((ROOT / 'before.json').exists(), 'no recovery snapshot; inspect artifacts without restarting')
        before = json.loads((ROOT / 'before.json').read_text())
        if DROP.exists():
            require((ROOT / 'dropin').exists() and DROP.read_text() == (ROOT / 'dropin').read_text(), 'runtime drop-in drift')
        require(CAP.read_text() == before['cap'], 'capacity drift')
        require(config(BASE) == before['config'], 'base configuration drift')
        require(OLD_DROP.read_text() == before['old_drop'] and OLD_OVERLAY.read_text() == before['old_overlay'], 'old timeout baseline drift')
        # Reconcile all runtime fields except the one intentional timeout change.
        current = snapshot(allow_missing=True, old=before['june'])
        require(current['unit'] in [before['unit'], activated_unit(before)], 'unit drift; inspect before rollback')
        require(current['others'] == before['others'] and current['routes'] == before['routes'], 'unrelated drift; inspect before rollback')
        if current['june'] is not None:
            require(invariant(current['june']) in [expected_runtime(before, False), expected_runtime(before, True)], 'runtime drift; inspect before rollback')
            current_env = env(current['june'])
            baseline_env = env(before['june'])
            activated_env = expected_env(before, True)
            require(current_env in [baseline_env, activated_env], 'environment drift; inspect before rollback')
        stage('rollback-starting')
        # Only the exact saved original ID may be treated as a Compose remnant.
        # No volume deletion. Renaming restores its original identity if no new
        # June exists; otherwise remove only that validated obsolete container.
        for old in current['renamed']:
            if current['june'] is None:
                run([D,'rename',old['Id'],NAME])
                current['june'] = old
            else:
                if old['State']['Running']:
                    run([D,'stop','--time','10',old['Id']])
                run([D,'rm',old['Id']])
        if DROP.exists():
            DROP.unlink()
        run(['systemctl', 'daemon-reload'])
        require(unit_state() == before['unit'], 'restored unit differs')
        # If failure preceded recreation, avoid an unnecessary backend restart.
        if current['june'] is None or current['june']['Id'] != before['june']['Id'] or not current['june']['State']['Running']:
            run(BASE + UP)
        verify(before, False)
        stage('rolled-back')
    else:
        raise ValueError('expected check, apply or rollback')

if __name__ == '__main__':
    main(sys.argv[1])
