// Explorer runs this once per selected file: wscript //E:JScript launch.js KIND FORMAT PATH
// Each copy drops its path into queue\KIND-FORMAT. Once that folder has been quiet for a while,
// one copy renames it under a lock and starts the converter.
var QUIET_MS = 2000;

var fso = new ActiveXObject("Scripting.FileSystemObject");
var args = WScript.Arguments;
var kind = args(0), format = args(1), path = args(2);
var root = fso.GetParentFolderName(WScript.ScriptFullName);
var queue = root + "\\queue";
var live = queue + "\\" + kind + "-" + format;

function now() { return new Date().getTime(); }
function unique() { return now() + "-" + String(Math.random()).substr(2); }
function makeFolder(folder) { try { fso.CreateFolder(folder); } catch (e) {} }

var request, out;
for (var tries = 0; ; tries++) {
  try {
    makeFolder(queue);
    makeFolder(live);
    request = live + "\\" + unique();
    out = fso.CreateTextFile(request, false, true);
    break;
  } catch (e) {
    if (tries >= 400) throw e;
    WScript.Sleep(25);
  }
}
out.Write(path);
out.Close();

var count = -1, since = now();
while (fso.FileExists(request)) {
  var seen = count;
  try { seen = fso.GetFolder(live).Files.Count; } catch (e) {}
  if (seen !== count) {
    count = seen;
    since = now();
  } else if (now() - since >= QUIET_MS) {
    var batch = queue + "\\batch-" + unique();
    var won = false;
    // A rename alone is not exclusive: several at once can all succeed. The open lock file is:
    // it cannot be deleted while held, and a dead holder releases it.
    var lock = null;
    try {
      if (fso.FileExists(live + ".lock")) fso.DeleteFile(live + ".lock");
      lock = fso.CreateTextFile(live + ".lock", false);
      if (fso.FileExists(request)) { fso.MoveFolder(live, batch); won = true; }
    } catch (e) {}
    if (lock) lock.Close();
    if (won) {
      var shell = new ActiveXObject("WScript.Shell");
      // Passed through the environment because Run expands %...% inside the command line
      var env = shell.Environment("Process");
      env("EC_APP") = root + "\\explorer-convert.ps1";
      env("EC_BATCH") = batch;
      shell.Run('"%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe" -NoProfile -ExecutionPolicy Bypass' +
        ' -File "%EC_APP%" ' + kind + " " + format + ' -Batch "%EC_BATCH%"', 0, false);
      break;
    }
  }
  WScript.Sleep(100);
}
