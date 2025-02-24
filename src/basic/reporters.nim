#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [terminal, paths]
export paths

type
  MsgKind* = enum
    Ignore = ""
    Error = "[Error] "
    Warning = "[Warning] ",
    Info = "[Info] ",
    Debug = "[Debug] "
    Trace = "[Trace] "

  Reporter* = object of RootObj
    verbosity*: MsgKind
    noColors*: bool
    assertOnError*: bool
    warnings*: int
    errors*: int
    messages: seq[(MsgKind, string, string)] # delayed output

var atlasReporter* = Reporter(verbosity: Info)

proc setAtlasVerbosity*(verbosity: MsgKind) =
  atlasReporter.verbosity = verbosity

proc setAtlasNoColors*(nc: bool) =
  atlasReporter.noColors = nc

proc setAtlasAssertOnError*(err: bool) =
  atlasReporter.assertOnError = err

proc atlasErrors*(): int =
  atlasReporter.errors

proc writeMessage(c: var Reporter; category: string; p, arg: string) =
  var msg = category
  if p.len > 0: msg.add "(" & p & ") "
  msg.add arg
  stdout.writeLine msg

proc writeMessage(c: var Reporter; k: MsgKind; p, arg: string) =
  if k == Ignore: return
  if k > c.verbosity: return
  # if k == Trace and c.verbosity < 1: return
  # elif k == Debug and c.verbosity < 2: return

  if c.noColors:
    writeMessage(c, $k, p, arg)
  else:
    let (color, style) =
      case k
      of Ignore: (fgWhite, styleDim)
      of Debug: (fgWhite, styleDim)
      of Trace: (fgBlue, styleBright)
      of Info: (fgGreen, styleBright)
      of Warning: (fgYellow, styleBright)
      of Error: (fgRed, styleBright)
    stdout.styledWriteLine(color, style, $k, resetStyle, fgCyan, "(", p, ")", resetStyle, " ", arg)

proc message(c: var Reporter; k: MsgKind; p, arg: string) =
  ## collects messages or prints them out immediately
  # c.messages.add (k, p, arg)
  writeMessage c, k, p, arg


proc warn*(c: var Reporter; p, arg: string) =
  c.message(Warning, p, arg)
  # writeMessage c, Warning, p, arg
  inc c.warnings

proc error*(c: var Reporter; p, arg: string) =
  if c.assertOnError:
    raise newException(AssertionDefect, p & ": " & arg)
  c.message(Error, p, arg)
  inc c.errors

proc info*(c: var Reporter; p, arg: string) =
  c.message(Info, p, arg)

proc trace*(c: var Reporter; p, arg: string) =
  c.message(Trace, p, arg)

proc debug*(c: var Reporter; p, arg: string) =
  c.message(Debug, p, arg)

proc writePendingMessages*(c: var Reporter) =
  for i in 0..<c.messages.len:
    let (k, p, arg) = c.messages[i]
    writeMessage c, k, p, arg
  c.messages.setLen 0

proc atlasWritePendingMessages*() =
  atlasReporter.writePendingMessages()

proc infoNow*(c: var Reporter; p, arg: string) =
  writeMessage c, Info, p, arg

proc fatal*(c: var Reporter, msg: string, prefix = "fatal", code = 1) =
  when defined(debug):
    writeStackTrace()
  writeMessage(c, Error, prefix, msg)
  quit 1

when not compiles($(Path("test"))):
  template `$`*(x: Path): string =
    string(x)

when not compiles(len(Path("test"))):
  template len*(x: Path): int =
    x.string.len()

proc warn*(c: var Reporter; p: Path, arg: string) =
  warn(c, $p, arg)

proc error*(c: var Reporter; p: Path, arg: string) =
  error(c, $p, arg)

proc info*(c: var Reporter; p: Path, arg: string) =
  info(c, $p, arg)

proc trace*(c: var Reporter; p: Path, arg: string) =
  trace(c, $p, arg)

proc debug*(c: var Reporter; p: Path, arg: string) =
  debug(c, $p, arg)

proc message*(k: MsgKind; p, arg: string) =
  message(atlasReporter, k, p, arg)

proc warn*(p: Path | string, arg: string) =
  warn(atlasReporter, $p, arg)

proc error*(p: Path | string, arg: string) =
  error(atlasReporter, $p, arg)

proc info*(p: Path | string, arg: string) =
  info(atlasReporter, $p, arg)

proc trace*(p: Path | string, arg: string) =
  trace(atlasReporter, $p, arg)

proc debug*(p: Path | string, arg: string) =
  debug(atlasReporter, $p, arg)

proc fatal*(msg: string | Path, prefix = "fatal", code = 1) =
  fatal(atlasReporter, msg, prefix, code)

proc infoNow*(p: Path | string, arg: string) =
  infoNow(atlasReporter, $p, arg)
