#
# Nimble package directory
#
# Copyright 2016-2022 Federico Ceratto <federico.ceratto@gmail.com>
# Released under GPLv3 License, see LICENSE file
#

import std/[
  asyncdispatch,
  deques,
  httpclient,
  httpcore,
  json,
  os,
  osproc,
  sequtils,
  sets,
  streams,
  strutils,
  tables,
  times,
  uri
]

from std/strformat import `&`
from std/xmltree import escape
from std/algorithm import sort, sorted, sortedByIt, reversed
from std/marshal import store, load
from std/posix import onSignal, SIGINT, SIGTERM, getpid
from std/times import epochTime

#from nimblepkg import getTagsListRemote, getVersionList
import jester,
  morelogging,
  sdnotify,
  statsd_client

import github, util, signatures, persist

const
  template_path = "./templates"
  git_bin_path = "/usr/bin/git"
  nim_bin_path = "/usr/bin/nim"
  nimble_bin_path = "/usr/bin/nimble"
  build_timeout_seconds = 60 * 4
  nimble_packages_polling_time_s = 10 * 60
  sdnotify_ping_time_s = 10
  build_expiry_time = initTimeInterval(minutes = 240)  # TODO: check version/commitish instead
  cache_fn = ".cache.json"

  xml_no_cache_headers = {
    "Cache-Control": "no-cache, no-store, must-revalidate, max-age=0, proxy-revalidate, no-transform",
    "Expires": "0",
    "Pragma": "no-cache",
    "Content-Type": "image/svg+xml"
  }


# init

type
  ProcessError = object of Exception
  BuildStatus {.pure.} = enum OK, Failed, Timeout, Running, Waiting
  DocBuildOutItem = object
    success_flag: bool
    filename, desc, output: string
  DocBuildOut = seq[DocBuildOutItem]
  PkgDocMetadata = object of RootObj
    fnames: seq[string]
    idx_fnames: seq[string]
    build_time: Time
    expire_time: Time
    last_commitish: string
    build_status: BuildStatus
    build_output: string
    doc_build_status: BuildStatus
    doc_build_output: DocBuildOut
    version: string
  RssItem = object
    title, desc, pubDate: string
    url, guid: Uri
  BuildHistoryItem = tuple
    name: string
    build_time: Time
    build_status: BuildStatus
    doc_build_status: BuildStatus
  PkgSymbol = object
    code, desc, itype, filepath: string
    line, col: int
  PkgSymbols = seq[PkgSymbol]

# the pkg name is normalized
var pkgs: Pkgs = newTable[string, Pkg]()
type PkgsDocFilesTable = Table[string, PkgDocMetadata]
# package name -> PkgDocMetadata
# initialized by scan_pkgs_dir
var pkgs_doc_files = newTable[string, PkgDocMetadata]()
var pkgs_waiting_build = initHashSet[string]()
var pkgs_building = initHashSet[string]()

# tag -> package name
# initialized/updated by load_packages
var packages_by_tag = newTable[string, seq[string]]()

# word -> package name
# initialized/updated by load_packages
var packages_by_description_word = newTable[string, seq[string]]()

# symbol -> seq[PkgSymbol]
# initialized by scan_pkgs_dir
var jsondoc_symbols = newTable[string, PkgSymbols]()

# pname, symbol -> seq[PkgSymbol]
# initialized by scan_pkgs_dir
type PkgSymbolsIndexer = tuple[pname, symbol: string]
var jsondoc_symbols_by_pkg = newTable[PkgSymbolsIndexer, PkgSymbols]()

# package access statistics
# volatile
var most_queried_packages = initCountTable[string]()

# build history
# volatile
const build_history_size = 100
var build_history = initDeque[BuildHistoryItem]()

# stats
var install_success_count = 0
var install_failure_count = 0
var doc_gen_success_count = 0
# disk-persisted cache

type
  PkgHistoryItem = object
    name: string
    first_seen_time: Time

  Cache = object of RootObj
    # package creation/update history - new ones at bottom
    pkgs_history: seq[PkgHistoryItem]
    # pkgs list. Extra data from GH is embedded
    #pkgs: TableRef[string, Pkg]

var cache: Cache

proc save(cache: Cache) =
  let f = newFileStream(cache_fn, fmWrite)
  log_debug "writing " & absolutePath(cache_fn)
  f.store(cache)
  f.close()

proc load_cache(): Cache =
  ## Load cache from disk or create empty cache
  log_debug "loading cache at $#" % cache_fn
  try:
    # FIXME
    #result.pkgs = newTable[string, Pkg]()
    result.pkgs_history = @[]
    load(newFileStream(cache_fn, fmRead), result)
    log_debug "cache loaded"
  except:
    log_info "initializing new cache"
    #result.pkgs = newTable[string, Pkg]()
    result.pkgs_history = @[]
    result.save()
    log_debug "new cache created"

proc save_metadata(j: PkgDocMetadata, fn: string) =
  ## Save package metadata
  log_debug "Saving to $#" % fn
  var k = PkgDocMetadata()
  deepCopy[PkgDocMetadata](k, j)
  let f = newFileStream(fn, fmWrite)
  k.build_output = uniescape(j.build_output)
  if k.version == "":
    k.version = "?"
  k.version = k.version.strip(chars = {'\0'})
  f.store(k)
  f.close()

proc load_metadata(fn: string): PkgDocMetadata =
  ## Load package metadata
  log_debug "Loading $#" % fn
  load(newFileStream(fn, fmRead), result)

proc scan_pkgs_dir(pkgs_root: string) =
  ## scan all packages dirs, populate jsondoc_symbols,
  ## jsondoc_symbols_by_pkg and pkgs_doc_files
  let pattern = pkgs_root / "*" / "nimpkgdir.json"
  # e.g /var/lib/nim_package_directory/cache/*/nimpkgdir.json
  log_info "scanning pattern '" & pattern & "'"
  for x in walkPattern(pattern):
    try:
      let pm: PkgDocMetadata = load_metadata(x)
      # TODO jsondoc_symbols, jsondoc_symbols_by_pkg
    except:
      # ignore metadata
      log_info "Load error: " & getCurrentExceptionMsg()
  log_info "----"


# HTML templates

include "templates/base.tmpl"
include "templates/empty.tmpl"
include "templates/home.tmpl"
include "templates/pkg.tmpl"
include "templates/pkg_list.tmpl"
include "templates/loader.tmpl"
include "templates/rss.tmpl"
include "templates/build_output.tmpl"

const
  build_success_badge = slurp "templates/success.svg"
  build_fail_badge = slurp "templates/fail.svg"
  build_waiting_badge = slurp "templates/build_waiting.svg"
  build_running_badge = slurp "templates/build_running.svg"
  doc_success_badge = slurp "templates/doc_success.svg"
  doc_fail_badge = slurp "templates/doc_fail.svg"
  doc_waiting_badge = slurp "templates/doc_waiting.svg"
  doc_running_badge = slurp "templates/doc_running.svg"
  version_badge_tpl = slurp template_path / "version-template-blue.svg"

#[
proc setup_seccomp() =
  ## Setup seccomp sandbox
  const syscalls = """accept,access,arch_prctl,bind,brk,close,connect,epoll_create,epoll_ctl,epoll_wait,execve,fcntl,fstat,futex,getcwd,getrlimit,getuid,ioctl,listen,lseek,mmap,mprotect,munmap,open,poll,read,readlink,recvfrom,rt_sigaction,rt_sigprocmask,sendto,set_robust_list,setsockopt,set_tid_address,socket,stat,uname,write"""
  let ctx = seccomp_ctx()
  for sc in syscalls.split(','):
    ctx.add_rule(Allow, sc)
  ctx.load()
]#

proc search_packages*(query: string): CountTable[string] =
  ## Search packages by name, tag and keyword
  let query = query.strip.toLowerAscii.split({' ', ','})
  var found_pkg_names = initCountTable[string]()
  for item in query:

    # matching by pkg name, weighted for full or partial match
    for pn in pkgs.keys():
      if item.normalize() == pn:
        found_pkg_names.inc(pn, val = 5)
      elif pn.contains(item.normalize()):
        found_pkg_names.inc(pn, val = 3)

    if packages_by_tag.hasKey(item):
      for pn in packages_by_tag[item]:
        # matching by tags is weighted more than by word
        found_pkg_names.inc(pn, val = 3)

    # matching by description, weighted 1
    if packages_by_description_word.hasKey(item.toLowerAscii):
      for pn in packages_by_description_word[item.toLowerAscii]:
        found_pkg_names.inc(pn, val = 1)

  # sort packages by best match
  found_pkg_names.sort()
  return found_pkg_names

proc append(build_history: var Deque[BuildHistoryItem], name: string,
    build_time: Time, build_status, doc_build_status: BuildStatus) =
  ## Add BuildHistoryItem to build history
  if build_history.len == build_history_size:
    discard build_history.popLast
  let i: BuildHistoryItem = (name, build_time, build_status, doc_build_status)
  build_history.addFirst(i)

type RunOutput = tuple[exit_code: int, elapsed: float, output: string]

#[
proc run_process(bin_path, desc, work_dir: string,
    timeout: int, log_output: bool,
    args: varargs[string, `$`]): (bool, string) {.discardable.} =
  ## Run command with timeout
  # TODO: async

  log_debug "running: <" & bin_path & " " & join(args, " ") & "> in " & work_dir

  var p = startProcess(
    bin_path, args=args,
    workingDir=work_dir,
    options={poStdErrToStdOut}
  )
  let exit_val = p.waitForExit(timeout=timeout * 1000)
  let stdout_str = p.outputStream().readAll()

  if log_output or (exit_val != 0):
    if stdout_str.len > 0:
      log_debug "Stdout: ---\n$#---" % stdout_str

  if exit_val == 0:
    log_debug "$# successful" % desc
  else:
    log.error "run_process: $# failed, exit value: $#" % [desc, $exit_val]
  return ((exit_val == 0), stdout_str)
]#

proc run_process2(bin_path, desc, work_dir: string,
    timeout: int, log_output: bool,
    args: seq[string]): Future[RunOutput] {.async.} =
  ## Run command asyncronously with timeout
  let
    t0 = epochTime()
    p = startProcess(
      bin_path,
      args = args,
      workingDir = work_dir,
      options = {poStdErrToStdOut}
    )
    pid = p.processID()

  var exit_code = 0
  var sleep_time_ms = 50
  while true:
    let elapsed = epochTime() - t0
    if elapsed > timeout.float:
      log_debug "timed out!"
      p.kill()
      exit_code = -2
      break

    exit_code = p.peekExitCode()
    case exit_code:
    of -1:
      # -1: still running, wait
      log_debug "waiting command thread $#..." % $pid
      await sleepAsync sleep_time_ms
      if sleep_time_ms < 1000:
        sleep_time_ms *= 2

    of 0:
      log_debug "waitForExit 0"
      discard p.waitForExit()
      break

    else:
      log_debug "waitForExit " & $exit_code
      discard p.waitForExit()
      break

  let elapsed = epochTime() - t0

  var output = ""
  let stdout_stream = p.outputStream()
  let new_output = stdout_stream.readAll()
  output.add new_output

  for line in new_output.splitLines():
    log_debug "[$#] $#> $#" % [$pid, $exit_code, line]

  return (exit_code, elapsed, output)

#[
proc fetch_pkg_using_nimble(pname: string): bool =
  let pkg_install_dir = conf.tmp_nimble_root_dir / pname

  var outp = run_process_old(nimble_bin_path, "nimble update",
    conf.tmp_nimble_root_dir, 10, true,
    "update", " --nimbleDir=" & conf.tmp_nimble_root_dir)
  assert outp.contains("Done")

  #if not conf.tmp_nimble_root_dir.dir_exists():
  outp = ""
  if true:
    # First install
    log_debug conf.tmp_nimble_root_dir, " is not existing"
    outp = run_process_old(nimble_bin_path, "nimble install", conf.tmp_nimble_root_dir,
      60, true,
      "install", pname, " --nimbleDir=./nyan", "-y")
    log_debug "Install successful"

  else:
    # Update pkg
    #outp = run_process_old(nimble_bin_path, "nimble install", "/", 60, true,
    #  "install", pname, " --nimbleDir=" & conf.tmp_nimble_root_dir, "-y")
    #  FIXME
    log_debug "Update successful"

  pkgs_doc_files[pname].build_output = outp
  return true
]#

proc fetch_and_build_pkg_using_nimble(pname: string) {.async.} =
  ## Run nimble install for a package using a dedicated directory
  let tmp_dir = conf.tmp_nimble_root_dir / pname
  log_debug "Starting nimble install $# --verbose --nimbleDir=$# -y" % [pname, tmp_dir]
  let po = await run_process2(
      nimble_bin_path,
      "nimble",
      ".",
      build_timeout_seconds,
      true,
      @["install", $pname, "--verbose", "--nimbleDir=$#" % tmp_dir, "-y",
          "--debug"],
    )

  let build_status: BuildStatus =
    if po.exit_code == 0:
      BuildStatus.OK
    elif po.exit_code == -2:
      BuildStatus.Timeout
    else:
      BuildStatus.Failed

  log_debug "Setting status ", build_status

  pkgs_doc_files[pname].build_status = build_status
  if build_status == BuildStatus.Timeout:
    pkgs_doc_files[pname].build_output = "** Install test timed out after " &
        $build_timeout_seconds & " seconds **\n\n" & po.output
  else:
    pkgs_doc_files[pname].build_output = po.output

  pkgs_doc_files[pname].build_time = getTime()
  pkgs_doc_files[pname].expire_time = getTime() + build_expiry_time

proc load_packages*() =
  ## Load packages.json
  ## Rebuild packages_by_tag, packages_by_description_word
  log_debug "loading $#" % conf.packages_list_fname
  pkgs.clear()
  if not conf.packages_list_fname.file_exists:
    log_info "packages list file not found. First run?"
    let new_pkg_raw = waitFor fetch_nimble_packages()
    log_info "writing $#" % absolutePath(conf.packages_list_fname)
    conf.packages_list_fname.writeFile(new_pkg_raw)

  let pkg_list = conf.packages_list_fname.parseFile
  for pdata in pkg_list:
    if not pdata.hasKey("name"):
      continue
    if not pdata.hasKey("tags"):
      continue
    # Normalize pkg name
    pdata["name"].str = pdata["name"].str.normalize()
    if pdata["name"].str in pkgs:
      log.warn "Duplicate pkg name $#" % pdata["name"].str
      continue

    pkgs[pdata["name"].str] = pdata

    for tag in pdata["tags"]:
      if not packages_by_tag.hasKey(tag.str):
        packages_by_tag[tag.str] = @[]
      packages_by_tag[tag.str].add pdata["name"].str

    # collect packages matching a word in their descriptions
    let orig_words = pdata["description"].str.split({' ', ','})
    for orig_word in orig_words:
      if orig_word.len < 3:
        continue # ignore short words
      let word = orig_word.toLowerAscii
      if not packages_by_description_word.hasKey(word):
        packages_by_description_word[word] = @[]
      packages_by_description_word[word].add pdata["name"].str

  log_info "Loaded ", $pkgs.len, " packages"

  # log_debug "writing $#" % conf.packages_list_fname
  # conf.packages_list_fname.writeFile(conf.packages_list_fname.readFile)

proc package_parent_dir(pname: string): string =
  ## Generate pkg parent dir
  # Full path example:
  # /var/lib/nim_package_dir/nimgame2
  conf.tmp_nimble_root_dir / pname

proc locate_pkg_root_dir(pname: string): string =
  ## Locate installed pkg root dir
  # Full path example:
  # /dev/shm/nim_package_dir/nimgame2/pkgs/nimgame2-0.1.0
  let pkgs_dir = conf.tmp_nimble_root_dir / pname / "pkgs"
  log_debug "scanning dir $#" % pkgs_dir
  for kind, path in walkDir(pkgs_dir, relative = true):
    log_debug "scanning $#" % path
    # FIXME: better heuristic
    if path.contains('-'):
      let chunks = path.split('-', maxsplit = 1)
      if chunks[0].normalize() == pname:
        result = pkgs_dir / path
        log_debug "Found pkg root: ", result
        return

  raise newException(Exception, "Root dir for $# not found" % pname)

proc build_docs(pname: string) {.async.} =
  ## Build docs
  let pkg_root_dir = locate_pkg_root_dir(pname)
  log_debug "Walking ", pkg_root_dir
  #for fname in pkg_root_dir.walkDirRec(filter={pcFile}): # Bug in walkDirRec
  var all_output: DocBuildOut = @[]
  var generated_doc_fnames: seq[string] = @[]
  var generated_idx_fnames: seq[string] = @[]

  var input_fnames: seq[string] = @[]
  for fname in pkg_root_dir.walkDirRec():
    if fname.endswith(".nim"):
      input_fnames.add fname

  for fname in input_fnames:
    log_debug "running nim doc for $#" % fname

    # TODO: enable --docSeeSrcUrl:<url>

    let desc = "nim doc --index:on $#" % fname
    let run_dir = fname.splitPath.head
    let po = await run_process2(
      nim_bin_path,
      desc,
      run_dir,
      10,
      true,
      @["doc", "--index:on", fname],
    )
    let success = (po.exit_code == 0)
    all_output.add DocBuildOutItem(
      success_flag: success,
      filename: fname,
      desc: desc,
      output: po.output
    )
    if success:
      # trim away <pkg_root_dir> and ".nim"
      let basename = fname[pkg_root_dir.len..^5]
      generated_doc_fnames.add basename & ".html"
      log_debug &"adding {basename}.html"

      for kind, path in walkDir(pkg_root_dir, relative = true):
        if path.endswith(".idx"):
          #generated_idx_fnames.add basename & ".idx"
          #idx_filenames.add path
          log_debug &"adding {pkg_root_dir} > path"
          #let chunks = path.split('-', maxsplit=1)
          #if chunks[0].normalize() == pname:
          #  result = pkgs_dir / path

  pkgs_doc_files[pname].doc_build_output = all_output
  pkgs_doc_files[pname].fnames = generated_doc_fnames
  pkgs_doc_files[pname].idx_fnames = generated_idx_fnames
  pkgs_doc_files[pname].doc_build_status =
    if (input_fnames.len == generated_doc_fnames.len): BuildStatus.OK
    else: BuildStatus.Failed


proc parse_jsondoc(fname: string, pkg_root_dir: string, pname: string) =
  ## Parse jsondoc items, add them to the global `jsondoc_symbols`
  ## and `jsondoc_symbols_by_pkg`
  # replace ".nim" with ".json"
  let (jsonf_dir, jsonf_basename, _) = splitFile(fname)
  var json_fn = jsonf_dir / jsonf_basename  & ".json"
  var json_data = ""
  try:
    log_debug &"reading {json_fn}"
    json_data = readFile(json_fn)
  except IOError:
    json_fn = jsonf_dir / "htmldocs" / jsonf_basename  & ".json"
    try:
      log_debug &"reading {json_fn}"
      json_data = readFile(json_fn)
    except IOError:
      log_debug "failed to read " & json_fn & " : " &
          getCurrentExceptionMsg()
      return

  try:
    var j = parseJson(json_data)
    if j.kind == JObject:
      j = j["entries"]
    for chunk in j:
      let symbol_name = chunk["name"].getStr()
      let description = chunk{"description"}.getStr().strip_html()
      let symbol = PkgSymbol(
        itype: chunk["type"].getStr(),
        desc: description,
        code: chunk["code"].getStr(),
        filepath: fname[pkg_root_dir.len..^1],
        line: chunk["line"].getInt(),
        col: chunk["col"].getInt(),
      )
      try:
        if not jsondoc_symbols[symbol_name].contains symbol:
          jsondoc_symbols[symbol_name].add(symbol)
      except KeyError:
        jsondoc_symbols[symbol_name] = @[symbol]

      let i: PkgSymbolsIndexer = (pname, symbol_name)
      try:
        if not jsondoc_symbols_by_pkg[i].contains symbol:
          jsondoc_symbols_by_pkg[i].add(symbol)
      except KeyError:
        jsondoc_symbols_by_pkg[i] = @[symbol]

  except:
    log_debug "failed to parse " & json_fn & " : " &
        getCurrentExceptionMsg()

proc generate_jsondoc(pname: string) {.async.} =
  ## Generate jsondoc items, add them to the global `jsondoc_symbols`
  ## and `jsondoc_symbols_by_pkg`
  let pkg_root_dir = locate_pkg_root_dir(pname)
  log_debug "Walking ", pkg_root_dir

  var input_fnames: seq[string] = @[]
  for fname in pkg_root_dir.walkDirRec():
    if fname.endswith(".nim"):
      input_fnames.add fname

  for fname in input_fnames:
    let desc = "nim jsondoc $#" % fname
    log_debug "running " & desc
    let run_dir = fname.splitPath.head
    let po = await run_process2(
      nim_bin_path,
      desc,
      run_dir,
      10,
      true,
      @["jsondoc", fname],
    )
    let success = (po.exit_code == 0)
    if success:
      parse_jsondoc(fname, pkg_root_dir, pname)

proc generate_install_stats(success: bool) =
  if success:
    stats.incr("install_succeded")
    inc install_success_count
  else:
    stats.incr("install_failed")
    inc install_failure_count

  let rate = install_success_count * 100 / (install_success_count + install_failure_count)
  stats.gauge("build_success_rate", rate)

proc generate_doc_build_stats() =
  # called only on success
  inc doc_gen_success_count
  if install_success_count == 0:
    return
  let rate = doc_gen_success_count * 100 / install_success_count
  stats.gauge("doc_gen_success_rate", rate)

proc fetch_and_build_pkg_if_needed(pname: string, force_rebuild = false) {.async.} =
  ## Fetch package and build docs
  ## Modifies pkgs_doc_files
  try:
    # A build has been already done or is currently running.
    if pkgs_doc_files.hasKey(pname):

      # Build already running
      if pname in pkgs_waiting_build or pname in pkgs_building:
        return

      # No need to rebuild yet
      if not force_rebuild and pkgs_doc_files[pname].expire_time > getTime():
        return

    # The package has never been built before: create PkgDocMetadata
    else:
      log_info "Starting FIRST build for " & pname
      let pm = PkgDocMetadata(
        fnames: @[],
        idx_fnames: @[],
      )
      pkgs_doc_files[pname] = pm

    # Wait for a slot before starting
    pkgs_waiting_build.incl pname   # lock
    pkgs_doc_files[pname].build_status = BuildStatus.Waiting
    pkgs_doc_files[pname].doc_build_status = BuildStatus.Waiting
    stats.gauge("pkgs_waiting_build_len", pkgs_waiting_build.len)

    while pkgs_building.len >= 1:
      log_debug "waiting for a build slot. Queue size: " & $pkgs_waiting_build.len
      if pkgs_waiting_build.len < 10:
        log_debug pkgs_waiting_build
      stats.gauge("pkgs_waiting_build_len", pkgs_waiting_build.len)
      await sleepAsync 1000

    # Start build
    pkgs_building.incl pname
    pkgs_waiting_build.excl pname
    pkgs_doc_files[pname].build_status = BuildStatus.Running
    pkgs_doc_files[pname].doc_build_status = BuildStatus.Running
    pkgs_doc_files[pname].build_time = getTime()
    pkgs_doc_files[pname].expire_time = getTime() + build_expiry_time
    stats.gauge("pkgs_waiting_build_len", pkgs_waiting_build.len)

    # Fetch or update pkg
    let url = pkgs[pname]["url"].str

    try:
      let t0 = epochTime()
      await fetch_and_build_pkg_using_nimble(pname)
      let elapsed = epochTime() - t0
      stats.gauge("build_time", elapsed)
    except:
      pkgs_building.excl pname  # unlock
      raise

    if pkgs_doc_files[pname].build_status != BuildStatus.OK:
      pkgs_building.excl pname  # unlock
      log_debug "fetch_and_build_pkg_if_needed failed - skipping doc generation"
      generate_install_stats(false)

      build_history.append(
        pname,
        pkgs_doc_files[pname].build_time,
        pkgs_doc_files[pname].build_status,
        pkgs_doc_files[pname].doc_build_status
      )
      let fn = package_parent_dir(pname) & "/nimpkgdir.json"
      save_metadata(pkgs_doc_files[pname], fn)
      return # install failed

    generate_install_stats(true)

    try:
      let t1 = epochTime()
      await build_docs(pname) # this can raise
      let elapsed = epochTime() - t1
      stats.gauge("doc_build_time", elapsed)
      generate_doc_build_stats()
    finally:
      pkgs_building.excl pname  # unlock

    build_history.append(
      pname,
      pkgs_doc_files[pname].build_time,
      pkgs_doc_files[pname].build_status,
      pkgs_doc_files[pname].doc_build_status
    )

    if pkgs[pname].hasKey("github_latest_version"):
      pkgs_doc_files[pname].version = pkgs[pname][
          "github_latest_version"].str.strip
    else:
      log_debug "FIXME github_latest_version"
      pkgs_doc_files[pname].version = "?"

    try:
      let t2 = epochTime()
      await generate_jsondoc(pname) # this can raise
      let elapsed = epochTime() - t2
      stats.gauge("jsondoc_build_time", elapsed)
    except:
      log.error("jsondoc failed for " & pname)

    let fn = package_parent_dir(pname) & "/nimpkgdir.json"
    save_metadata(pkgs_doc_files[pname], fn)
    try:
      let pm: PkgDocMetadata = load_metadata(fn)
    except:
      log.error("JSON: created broken file: " & fn)
  except:
    log.error "build failed for " & pname & " " & getCurrentExceptionMsg()

proc wait_build_completion(pname: string) {.async.} =
  let t0 = epochTime()
  while pname in pkgs_waiting_build or pname in pkgs_building:
    let elapsed = epochTime() - t0
    if elapsed > build_timeout_seconds:
      log_debug "wait timed out!"
      stats.incr("build_timed_out")
      break
    log_debug "waiting already running build for $# $#s..." % [pname, $int(elapsed)]
    await sleepAsync 1000

proc translate_term_colors*(outp: string): string =
  ## Translate terminal colors into HTML with CSS classes
  const sequences = @[
    ("[36m[2m", "<span>"),
    ("[32m[1m", """<span class="term-success">"""),
    ("[33m[1m", """<span class="term-red">"""),
    ("[31m[1m", """<span class="term-red">"""),
    ("[36m[1m", """<span class="term-blue">"""),
    ("[0m[31m[0m", "</span>"),
    ("[0m[32m[0m", "</span>"),
    ("[0m[33m[0m", "</span>"),
    ("[0m[36m[0m", "</span>"),
    ("[0m[0m", "</span>"),
    ("[2m", "<span>"),
    ("[36m", "<span>"),
    ("[33m", """<span class="term-blue">"""),
  ]
  result = outp
  for s in sequences:
    result = result.replace(s[0], s[1])

proc sorted*[T](t: CountTable[T]): CountTable[T] =
  ## Return sorted CountTable
  var tcopy = t
  tcopy.sort()
  tcopy

proc top_keys*[T](t: CountTable[T], n: int): seq[T] =
  ## Return CountTable most common keys
  result = @[]
  var tcopy = t
  tcopy.sort()
  for k in keys(tcopy):
    result.add k
    if result.len == n:
      return


# Jester settings

settings:
  port = conf.port

# routes

router mainRouter:

  get "/about.html":
    include "templates/about.tmpl"
    resp base_page(request, generate_about_page())

  get "/":
    log_req request
    stats.incr("views")

    # Grab the most queried packages
    var top_pkgs: seq[Pkg] = @[]
    for pname in top_keys(most_queried_packages, 5):
      if pkgs.hasKey(pname):
        top_pkgs.add pkgs[pname]

    # Grab the newest packages
    log_debug "pkgs history len: $#" % $cache.pkgs_history.len
    var new_pkgs: seq[Pkg] = @[]
    for n in 1..min(cache.pkgs_history.len, 10):
      let package_name: string =
        if cache.pkgs_history[^n].name.len > 4 and cache.pkgs_history[^n].name[0..3] == "nim-":
          cache.pkgs_history[^n].name[4..^1].normalize()
        else:
          cache.pkgs_history[^n].name.normalize()
      if pkgs.hasKey(package_name):
        new_pkgs.add pkgs[package_name]
      else:
        log_debug "$# not found in package list" % package_name

    # Grab trending packages, as measured by GitHub
    let trending_pkgs = await fetch_trending_packages(request, pkgs)

    resp base_page(request, generate_home_page(top_pkgs, new_pkgs, trending_pkgs))

  get "/search":
    log_req request
    stats.incr("views")

    var searched_pkgs: seq[Pkg] = @[]
    for name in search_packages(@"query").keys():
      searched_pkgs.add pkgs[name]
    stats.gauge("search_found_pkgs", searched_pkgs.len)

    let body = generate_search_box(@"query") & generate_pkg_list_page(searched_pkgs)
    resp base_page(request, body)

  get "/build_history.html":
    ## build history and status
    include "templates/build_history.tmpl"
    log_req request

    resp base_page(request, generate_build_history_page(build_history, pkgs_waiting_build, pkgs_building))

  get "/pkg/@pkg_name/?":
    log_req request
    stats.incr("views")
    let pname = normalize(@"pkg_name")
    if not pkgs.hasKey(pname):
      resp base_page(request, "Package not found")

    most_queried_packages.inc pname
    asyncCheck fetch_and_build_pkg_if_needed(pname)

    let pkg = pkgs[pname]
    let url = pkg["url"].str
    if url.startswith("https://github.com/") or url.startswith("http://github.com/"):
      if not pkg.hasKey("github_last_update_time") or pkg["github_last_update_time"].num +
          github_caching_time < epochTime().int:
        # pkg is on GitHub and needs updating
        pkg["github_last_update_time"] = newJInt epochTime().int
        let owner = url.split('/')[3]
        let repo_name = url.split('/')[4]
        pkg["github_owner"] = newJString owner
        pkg["github_readme"] = await fetch_github_readme(owner, repo_name)
        pkg["doc"] = await fetch_github_doc_pages(owner, repo_name)
        await pkg.fetch_github_versions(owner, repo_name)

    resp base_page(request, generate_pkg_page(pkg))

  post "/update_package":
    ## Create or update a package description
    log_req request
    stats.incr("views")
    const required_fields = @["name", "url", "method", "tags", "description",
      "license", "web", "signatures", "authorized_keys"]
    var pkg_data: JsonNode
    try:
      pkg_data = parseJson(request.body)
    except:
      log_info "Unable to parse JSON payload"
      halt Http400, "Unable to parse JSON payload"

    for field in required_fields:
      if not pkg_data.hasKey(field):
        log_info "Missing required field $#" % field
        halt Http400, "Missing required field $#" % field

    let signature = pkg_data["signatures"][0].str

    try:
      let pkg_data_copy = pkg_data.copy()
      pkg_data_copy.delete("signatures")
      let key_id = verify_gpg_signature(pkg_data_copy, signature)
      log_info "received key", key_id
    except:
      log_info "Invalid signature"
      halt Http400, "Invalid signature"

    let name = pkg_data["name"].str

    # TODO: locking
    load_packages()

    # the package exists with identical name
    let pkg_already_exists = pkgs.hasKey(name)

    if not pkg_already_exists:
      # scan for naming collisions
      let norm_name = name.normalize()
      for existing_pn in pkgs.keys():
        if norm_name == existing_pn.normalize():
          log.info "Another package named $# already exists" % existing_pn
          halt Http400, "Another package named $# already exists" % existing_pn

    if pkg_already_exists:
      try:
        let old_keys = pkgs[name]["authorized_keys"].getElems.mapIt(it.str)
        let pkg_data_copy = pkg_data.copy()
        pkg_data_copy.delete("signatures")
        let key_id = verify_gpg_signature_is_allowed(pkg_data_copy, signature, old_keys)
        log_info "$# updating package $#" % [key_id, name]
      except:
        log_info "Key not accepted"
        halt Http400, "Key not accepted"

    pkgs[name] = pkg_data

    var new_pkgs = newJArray()
    for pname in toSeq(pkgs.keys()).sorted(system.cmp):
      new_pkgs.add pkgs[pname]
    conf.packages_list_fname.writeFile(new_pkgs.pretty.cleanup_whitespace)

    log_info if pkg_already_exists: "Updated existing package $#" % name
      else: "Added new package $#" % name
    resp base_page(request, "OK")

  get "/packages.json":
    ## Serve the packages list file
    log_req request
    stats.incr("views")
    resp conf.packages_list_fname.readFile

  get "/api/v1/package_count":
    ## Serve the package count
    log_req request
    stats.incr("views")
    resp $pkgs.len

  include "templates/doc_files_list.tmpl"
  get "/docs/@pkg_name/?":
    ## Serve hosted docs for a package: summary page
    log_req request
    stats.incr("views")
    let pname = normalize(@"pkg_name")
    if not pkgs.hasKey(pname):
      resp base_page(request, "<p>Package not found</p>")

    most_queried_packages.inc pname

    # Check out pkg and build docs. Modifies pkgs_doc_files
    asyncCheck fetch_and_build_pkg_if_needed(pname)
    await wait_build_completion(pname)

    # Show files summary
    resp base_page(request,
      generate_doc_files_list_page(pname, pkgs_doc_files[pname])
    )

  get "/docs/@pkg_name/idx_summary.json":
    ## Serve hosted docs for a package: IDX summary
    log_req request
    stats.incr("views")
    let pname = normalize(@"pkg_name")
    if not pkgs.hasKey(pname):
      resp base_page(request, "<p>Package not found</p>")

    # Check out pkg and build docs. Modifies pkgs_doc_files
    await fetch_and_build_pkg_if_needed(pname)
    await wait_build_completion(pname)

    let pkg_root_dir =
      try:
        locate_pkg_root_dir(pname)
      except:
        halt Http400
        ""

    var idx_filenames: seq[string] = @[]
    for kind, path in walkDir(pkg_root_dir, relative = true):
      if path.endswith(".idx"):
        idx_filenames.add path
        #let chunks = path.split('-', maxsplit=1)
        #if chunks[0].normalize() == pname:
        #  result = pkgs_dir / path

      # Show files summary
    let s = %* {"version": 1, "idx_filenames": idx_filenames}
    resp $s

  #get "/docs/@pkg_name_and_doc_path":
  get "/docs/@pkg_name/@a?/?@b?/?@c?/?@d?":
    ## Serve hosted docs and idx files for a package
    log_req request
    stats.incr("views")
    let pname = normalize(@"pkg_name")
    if not pkgs.hasKey(pname):
      resp base_page(request, "<p>Package not found</p>")

    most_queried_packages.inc pname

    # Check out pkg and build docs. Modifies pkgs_doc_files
    asyncCheck fetch_and_build_pkg_if_needed(pname)
    await wait_build_completion(pname)

    let pkg_root_dir =
      try:
        locate_pkg_root_dir(pname)
      except:
        halt Http400
        ""

    # Horrible hack
    let messy_path = @"a" / @"b" / @"c" / @"d"
    let doc_path = strip(messy_path, true, true, {'/'})

    if not (doc_path.endswith(".html") or doc_path.endswith(".idx")):
      log_debug "Refusing to serve doc path $# $#" % [pname, doc_path]
      halt Http400

    log_debug "Attempting to serve doc path $# $#" % [pname, doc_path]

    # Example: /docs/nimgame2/nimgame2/audio.html
    # ..serves:
    # /dev/shm/nim_package_dir/nimgame2/pkgs/nimgame2-0.1.0/nimgame2/audio.html

    let fn = pkg_root_dir / doc_path
    if not file_exists(fn):
      log_info "error serving $# - not found" % fn

      let fn2 = pkg_root_dir / "htmldocs" / doc_path
      if not file_exists(fn2):
        log_info "error serving $# - not found" % fn2

        resp base_page(request, """
          <p>Sorry, that file does not exists.
          <a href="/pkg/$#">Go back to $#</a>
          </p>
          """ % [pname, pname])

    # Serve doc or idx file
    if doc_path.endswith(".idx"):
      resp readFile(fn)
    else:
      let head = """<h4>Return to <a href="/"> Nimble Directory</a></h4><h4>Doc files for <a href="/pkg/$#">$#</a></h4>""" % [pname, pname]
      let page = head & fn.readFile()
      resp empty_page(request, page)

  get "/loader":
    log_req request
    stats.incr("views")
    resp base_page(request,
      generate_loader_page()
    )

  get "/packages.xml":
    ## New and updated packages feed
    log_req request
    stats.incr("views_rss")
    let baseurl = conf.public_baseurl.parseUri
    let url = baseurl / "packages.xml"

    var rss_items: seq[RssItem] = @[]
    for item in cache.pkgs_history:
      let pn = item.name.normalize()
      if not pkgs.hasKey(pn):
        #log_debug "skipping $#" % pn
        continue

      let pkg = pkgs[pn]
      let item_url = baseurl / "pkg" / pn
      let i = RssItem(
        title: pn,
        desc: xmltree.escape(pkg["description"].str),
        url: item_url,
        guid: item_url,
        pubdate: $item.first_seen_time.utc.format("ddd, dd MMM yyyy hh:mm:ss zz")
      )
      rss_items.add i

    let r = generate_rss_feed(
      title = "Nim packages",
      desc = "New and updated Nim packages",
      url = url,
      build_date = getTime().utc.format("ddd, dd MMM yyyy hh:mm:ss zz"),
      pub_date = getTime().utc.format("ddd, dd MMM yyyy hh:mm:ss zz"),
      ttl = 3600,
      rss_items
    )
    resp(r, contentType = "application/rss+xml")

  get "/stats":
    log_req request
    stats.incr("views")
    resp base_page(request, """
<div class="container" style="padding-top: 10rem;">
  <p class="text-center">Runtime: $#</p>
  <p class="text-center">Queried packages count: $#</p>
</div>
    """ % [$cpuTime(), $len(most_queried_packages)])

  # CI Routing

  get "/ci":
    ## CI summary
    log_req request
    stats.incr("views")
    #@bottle.view('index')
    #refresh_build_num()
    discard

  get "/ci/install_report":
    log_req request
    stats.incr("views")
    discard

  get "/ci/badges/@pkg_name/version.svg":
    ## Version badge. Set HTTP headers to control caching.
    log_req request
    stats.incr("views")
    let pname = normalize(@"pkg_name")
    if not pkgs.hasKey(pname):
      resp base_page(request, "Package not found")

    most_queried_packages.inc pname
    asyncCheck fetch_and_build_pkg_if_needed(pname)
    try:
      let md = pkgs_doc_files[pname]
      let version =
        if md.version == "":
          "..."
        else:
          md.version.strip(chars = {'\0'})
      let badge = version_badge_tpl % [version, version]
      resp(Http200, xml_no_cache_headers, badge)
    except:
      log_debug getCurrentExceptionMsg()
      let badge = version_badge_tpl % ["none", "none"]
      resp(Http200, xml_no_cache_headers, badge)

  get "/ci/badges/@pkg_name/nimdevel/status.svg":
    ## Status badge
    ## Set HTTP headers to control caching.
    log_req request
    stats.incr("views")
    let pname = normalize(@"pkg_name")
    if not pkgs.hasKey(pname):
      resp base_page(request, "Package not found")

    most_queried_packages.inc pname

    # This might start a build here and populate pkgs_doc_files[pname]
    # or fail before setting pkgs_doc_files or not run at all
    asyncCheck fetch_and_build_pkg_if_needed(pname)

    let build_status =
      try:
        pkgs_doc_files[pname].build_status
      except KeyError:
        log.error "status badge bug"
        BuildStatus.Failed

    let badge =
      case build_status
      of BuildStatus.OK:
        build_success_badge
      of BuildStatus.Failed:
        build_fail_badge
      of BuildStatus.Timeout:
        build_fail_badge
      of BuildStatus.Running:
        build_running_badge
      of BuildStatus.Waiting:
        build_waiting_badge
    resp(Http200, xml_no_cache_headers, badge)

  get "/ci/badges/@pkg_name/nimdevel/docstatus.svg":
    ## Doc build status badge
    ## Set HTTP headers to control caching.
    log_req request
    stats.incr("views")
    let pname = normalize(@"pkg_name")
    if not pkgs.hasKey(pname):
      resp base_page(request, "Package not found")

    most_queried_packages.inc pname

    asyncCheck fetch_and_build_pkg_if_needed(pname)

    let doc_build_status =
      try:
        pkgs_doc_files[pname].doc_build_status
      except KeyError:
        log.error "doc build status badge bug"
        BuildStatus.Running

    let badge =
      case doc_build_status
      of BuildStatus.OK:
        doc_success_badge
      of BuildStatus.Failed:
        doc_fail_badge
      of BuildStatus.Timeout:
        doc_fail_badge
      of BuildStatus.Waiting:
        doc_waiting_badge
      of BuildStatus.Running:
        doc_running_badge
    resp(Http200, xml_no_cache_headers, badge)

  get "/ci/badges/@pkg_name/nimdevel/output.html":
    ## Build output
    log_req request
    stats.incr("views")
    log_info "$#" % $request.ip
    let pname = normalize(@"pkg_name")
    if not pkgs.hasKey(pname):
      resp base_page(request, "Package not found")

    most_queried_packages.inc pname
    asyncCheck fetch_and_build_pkg_if_needed(pname)
    await wait_build_completion(pname)
    try:
      let outp = pkgs_doc_files[pname].build_output
      let build_output = translate_term_colors(outp)
      resp base_page(request, generate_run_output_page(
        pname,
        build_output,
        pkgs_doc_files[pname].build_time,
        pkgs_doc_files[pname].expire_time,
      ))
    except KeyError:
      halt Http400

  get "/ci/badges/@pkg_name/nimdevel/doc_build_output.html":
    ## Doc build output
    log_req request
    stats.incr("views")
    log_info "$#" % $request.ip
    let pname = normalize(@"pkg_name")
    if not pkgs.hasKey(pname):
      resp base_page(request, "Package not found")

    most_queried_packages.inc pname
    asyncCheck fetch_and_build_pkg_if_needed(pname)
    await wait_build_completion(pname)
    try:
      var doc_build_html = ""
      for o in pkgs_doc_files[pname].doc_build_output:
        if o.success_flag:
          doc_build_html.add """<div class="doc_build_success">"""
        else:
          doc_build_html.add """<div class="doc_build_fail">"""
        doc_build_html.add "<p>$#</p>" % o.filename
        doc_build_html.add "<p>$#</p>" % o.desc
        let t = translate_term_colors(o.output)
        doc_build_html.add "<p>$#</p>" % t
        doc_build_html.add "</div>"

      resp base_page(request, generate_run_output_page(
        pname,
        doc_build_html,
        pkgs_doc_files[pname].build_time,
        pkgs_doc_files[pname].expire_time,
      ))
    except KeyError:
      halt Http400

  get "/api/v1/status/@pkg_name":
    ## Package build status in a simple JSON
    log_req request
    let pname = normalize(@"pkg_name")
    let status =
      if pname in pkgs_waiting_build:
        "waiting"
      elif pname in pkgs_building:
        "building"
      elif pkgs_doc_files.hasKey(pname):
        "done"
      else:
        "unknown"

    let build_time =
      try:
        $pkgs_doc_files[pname].build_time.utc:
      except KeyError:
        ""

    let s = %* {"status": status, "build_time": build_time}
    resp $s

  post "/ci/rebuild/@pkg_name":
    ## Force new build
    log_req request
    let pname = normalize(@"pkg_name")
    asyncCheck fetch_and_build_pkg_if_needed(pname, force_rebuild = true)
    resp "ok"

  get "/robots.txt":
    ## Serve robots.txt to throttle bots
    const robots = """
User-agent: DataForSeoBot
Disallow: /

User-agent: *
Disallow: /about.html
Disallow: /api
Disallow: /ci
Disallow: /docs
Disallow: /loader
Disallow: /pkg
Disallow: /search
Disallow: /searchitem
Crawl-delay: 300
    """
    resp(robots, contentType = "text/plain")

  include "templates/jsondoc_symbols.tmpl" # generate_jsondoc_symbols_page

  get "/searchitem":
    ## Search for jsondoc symbol across all packages
    log_req request
    stats.incr("views")
    let query = @"query"
    let matches =
      try:
        jsondoc_symbols[query]
      except KeyError:
        @[]
    let body = generate_jsondoc_symbols_page(matches)
    resp base_page(request, body)

  template resp*(content: JsonNode): typed =
    resp($content, contentType = "application/json")

  get "/api/v1/search_symbol":
    ## Search for jsondoc symbol across all packages
    log_req request
    stats.incr("views")
    let matches =
      try:
        jsondoc_symbols[@"symbol"]
      except KeyError:
        @[]
    resp %matches

  include "templates/jsondoc_pkg_symbols.tmpl" # generate_jsondoc_pkg_symbols_page

  post "/searchitem_pkg":
    ## Search for jsondoc symbol in one package
    log_req request
    stats.incr("views")
    let pname = normalize(@"pkg_name").strip()
    let query = @("query").strip()
    let url = pkgs[pname]["url"].str.strip(chars = {'/'}, leading = false)
    let matches =
      try:
        jsondoc_symbols_by_pkg[(pname, query)]
      except KeyError:
        @[]
    let body = generate_jsondoc_pkg_symbols_page(matches, url)
    resp body

  error Http404:
    resp Http404, "Looks you took a wrong turn somewhere."

  error Exception:
    resp Http500, "Something bad happened: " & exception.msg

proc run_systemd_sdnotify_pinger(ping_time_s: int) {.async.} =
  ## Ping systemd watchdog using sd_notify
  const msg = "NOTIFY_SOCKET env var not found - pinging to logfile"
  if not existsEnv("NOTIFY_SOCKET"):
    log_info msg
    echo msg
    while true:
      log_debug "*ping*"
      await sleepAsync ping_time_s * 1000
    # never break

  let sd = newSDNotify()
  sd.notify_ready()
  sd.notify_main_pid(getpid())
  var t = epochTime()
  while true:
    sd.ping_watchdog()
    stats.gauge("build_time", epochTime() - t)
    t = epochTime()

    await sleepAsync ping_time_s * 1000


proc poll_nimble_packages(poll_time_s: int) {.async.} =
  ## Poll GitHub for packages.json
  ## Overwrites the packages.json local file!
  log_debug "starting GH packages.json polling"
  var first_run = true
  while true:
    if first_run:
      first_run = false
    else:
      await sleepAsync poll_time_s * 1000
    log_debug "Polling GitHub packages.json"
    try:
      let new_pkg_raw = await fetch_nimble_packages()
      if new_pkg_raw == conf.packages_list_fname.readFile:
        log_debug "No changes"
        stats.gauge("packages_all_known", pkgs.len)
        stats.gauge("packages_history", cache.pkgs_history.len)
        continue

      for pdata in new_pkg_raw.parseJson:
        if pdata.hasKey("name"):
          let pname = pdata["name"].str.normalize()
          if not pkgs.hasKey(pname):
            cache.pkgs_history.add PkgHistoryItem(name: pname,
                first_seen_time: getTime())
            log_debug "New pkg added on GH: $#" % pname

      cache.save()
      log_debug "writing $#" % (getCurrentDir() / conf.packages_list_fname)
      conf.packages_list_fname.writeFile(new_pkg_raw)
      load_packages()

      for item in cache.pkgs_history:
        let pname = item.name.normalize()
        if not pkgs.hasKey(pname):
          log_debug "$# is gone" % pname

      stats.gauge("packages_all_known", pkgs.len)
      stats.gauge("packages_history", cache.pkgs_history.len)

    except:
      log.error getCurrentExceptionMsg()


onSignal(SIGINT, SIGTERM):
  ## Exit signal handler
  log.info "Exiting"
  cache.save()
  quit()


proc main() =
  #setup_seccomp()
  log_info "starting"
  conf.tmp_nimble_root_dir.createDir()
  load_packages()
  cache = load_cache()
  scan_pkgs_dir(conf.tmp_nimble_root_dir)
  asyncCheck run_systemd_sdnotify_pinger(sdnotify_ping_time_s)
  asyncCheck poll_nimble_packages(nimble_packages_polling_time_s)

  log_info "starting server"
  var server = initJester(mainRouter)
  server.serve()

when isMainModule:
  main()
