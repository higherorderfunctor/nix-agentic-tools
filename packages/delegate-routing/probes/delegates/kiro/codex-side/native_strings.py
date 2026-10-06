import hashlib,json,pathlib,subprocess
# codex:R7 (G only) — string hits in the pinned native binary; writes native-strings.json to the cwd.
import os,sys
S=pathlib.Path(__file__).resolve().parent
sys.path.insert(0,str(S.parents[1]/'common'))
import pin  # noqa: E402
B=pathlib.Path(os.environ.get('KIRO_PKG') or pin.package('kiro-cli.unwrapped'))/'bin'/'.kiro-cli-chat-wrapped'
lines=subprocess.check_output(['strings','-a',str(B)],text=True).splitlines()
terms=['api.subagentTimeout','use_subagent.rs','only one task','Only one task','KIRO_ENABLED_FEATURES','enableMainAgentSubagentTool','max_parallel','maxParallel','subagentMax','chat.agentEngine','chat.defaultModel','chat.modelDefaults','chat.defaultInterruptBehavior']
out=[{'line':i+1,'term':term,'text':l[:12000]} for i,l in enumerate(lines) for term in terms if term in l]
pathlib.Path('native-strings.json').write_text(json.dumps({'binarySha256':hashlib.sha256(B.read_bytes()).hexdigest(),'mark':'G','matches':out},indent=2))
print('G string matches',len(out))
