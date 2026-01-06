import std/[asynchttpserver, asyncdispatch, os, strutils, uri, paths]

const
  DefaultHost = "0.0.0.0"
  DefaultPort = Port(6767)
  BasePath = "/atlas-packages/"

proc mimeTypeFor(path: string): string =
  case path.splitFile().ext.toLowerAscii()
  of ".json": "application/json"
  of ".gz": "application/gzip"
  of ".xz": "application/x-xz"
  of ".tar": "application/x-tar"
  else: "application/octet-stream"

proc safeLocalPath(root: Path; urlPath: string): Path =
  var path = decodeUrl(urlPath)
  path = path.replace("\\", "/")
  if path.startsWith("/"):
    path = path[1..^1]
  if path.len == 0 or path.contains("..") or path.contains(":"):
    return Path""
  let rootAbs = root.absolutePath
  let candidate = (rootAbs / Path(path)).absolutePath
  if not candidate.isRelativeTo(rootAbs):
    return Path""
  result = candidate

proc serveArchive(req: Request; root: Path; urlPath: string) {.async.} =
  let localPath = safeLocalPath(root, urlPath)
  if localPath.string.len == 0 or not fileExists(localPath.string):
    await req.respond(Http404, "Not Found\n")
    return
  if dirExists(localPath.string):
    await req.respond(Http404, "Not Found\n")
    return
  let data = readFile(localPath.string)
  var headers = newHttpHeaders()
  headers["Content-Type"] = mimeTypeFor(localPath.string)
  await req.respond(Http200, data, headers)

proc main() =
  let args = commandLineParams()
  let root =
    if args.len > 0: args[0].Path
    else: Path"pkg_archive"
  if not dirExists(root.string):
    echo "Archive directory not found: ", root
    quit(1)
  let rootAbs = root.absolutePath
  echo "Serving archive from ", rootAbs
  echo "Listening on http://", DefaultHost, ":", int(DefaultPort), BasePath
  var server = newAsyncHttpServer()
  proc handler(req: Request) {.async.} =
    if not req.url.path.startsWith(BasePath):
      await req.respond(Http404, "Not Found\n")
      return
    let urlPath = req.url.path[BasePath.len - 1..^1]
    await serveArchive(req, rootAbs, urlPath)
  waitFor server.serve(DefaultPort, handler, address = DefaultHost)

when isMainModule:
  main()
