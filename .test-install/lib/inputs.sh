#!/data/data/com.termux/files/usr/bin/bash
# inputs.sh — **具名输入角色**的解析与原子冻结。
#
# 为什么要有这一层（而不是让每条 case 自己临时决定装哪个版本）:
#   "用户实际会装到哪个版本"这件事，同一轮里只能回答一次。若让各 case 各自
#   解析 `latest`，轻则重复联网，重则**一轮之内拿到两个不同的目标**——那样
#   receipt 声称的"同一组输入"就是假的。
#
# 生命周期（顺序是契约的一部分）:
#   选择 case → 检查可提前判断的前置 → 解析并原子冻结输入 → 生成 build receipt → 执行
# 不选任何需要该输入的 case，就**根本不去解析**（`help`/`list`/`validate` 与
# 纯离线 profile 因此不会因为这一层而联网）。
#
# 当前只实现**一个具名角色** `default-target`（= 用户走默认安装路径会拿到的那个
# 版本）。顾问明确否掉了"现在就建通用依赖求解器"：支持边界版本、条件补丁正例
# 都是**将来的额外具名输入**，不是这个角色的参数。
#
# 本层**只负责选版本**，不假装锁住了整棵依赖树: 顶层包精确 ≠ 依赖树固定
# （传递依赖、平台可选依赖、npm 版本、既有 lockfile 都会改变最终装出来的东西）。
# 实际装出来的对象由 case 在安装后记录，见 DECISIONS 的 ADR-009。

set -uo pipefail

NPM_REGISTRY_DEFAULT="https://registry.npmjs.org/"
NPM_PKG_DEFAULT="@deepseek-ai/dsh"
NPM_SPEC_DEFAULT="${NPM_PKG_DEFAULT}@latest"

inputs_npm_registry() { printf '%s\n' "${DSH_NPM_REGISTRY:-$NPM_REGISTRY_DEFAULT}"; }

# 解析 `<pkg>@<selector>`。**刻意只支持两种 selector**：dist-tag 或精确版本。
# 范围（`^1.2.3`、`~`、`||`）、alias、URL、`latest || next` 这类 npm 语法一律拒绝：
# 要么诚实支持，要么明确报错，不许把接口叫 spec 却偷偷只实现一半、
# 然后在 receipt 里留下一个自己都解释不清的"解析结果"。
inputs_parse_spec() { # $1=spec -> 设置 INPUTS_PKG / INPUTS_SEL
  local spec="$1" rest
  case "$spec" in
    @*)
      rest="${spec#@}"
      INPUTS_PKG="@${rest%%@*}"
      INPUTS_SEL="${rest#*@}"
      [ "$INPUTS_SEL" = "$rest" ] && INPUTS_SEL="" ;;
    *)
      INPUTS_PKG="${spec%%@*}"
      INPUTS_SEL="${spec#*@}"
      [ "$INPUTS_SEL" = "$spec" ] && INPUTS_SEL="" ;;
  esac
  [ -n "$INPUTS_PKG" ] && [ -n "$INPUTS_SEL" ] || {
    echo "非法 npm spec（要 <包名>@<dist-tag|精确版本>）: $spec" >&2; return 1; }
  case "$INPUTS_PKG" in
    *[!a-z0-9._/@-]*|*//*|/*|*/) echo "非法包名: $INPUTS_PKG" >&2; return 1 ;;
  esac
  case "$INPUTS_PKG" in
    @*/*|*[!@]*) ;;
  esac
  # 范围/别名/URL/多条件的特征字符，一律拒绝
  case "$INPUTS_SEL" in
    *'^'*|*'~'*|*'>'*|*'<'*|*'*'*|*'|'*|*' '*|*'://'*|*'/'*|*=*)
      echo "不支持的 selector（只接受 dist-tag 或精确版本）: $INPUTS_SEL" >&2; return 1 ;;
  esac
  if [[ "$INPUTS_SEL" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.+-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; then
    INPUTS_KIND=version
  elif [[ "$INPUTS_SEL" =~ ^[A-Za-z][A-Za-z0-9._-]*$ ]]; then
    INPUTS_KIND=dist-tag
  else
    echo "无法判定的 selector: $INPUTS_SEL" >&2; return 1
  fi
  return 0
}

# 取 registry 元数据（stdout = JSON）。失败时打印原因并返回 1。
inputs_fetch_meta() { # $1=pkg $2=可选精确版本
  local pkg="$1" ver="${2:-}" url
  local reg; reg="$(inputs_npm_registry)"
  url="${reg%/}/$pkg"
  [ -n "$ver" ] && url="$url/$ver"
  command -v curl >/dev/null 2>&1 || { echo "缺少 curl" >&2; return 1; }
  curl -sS --max-time 30 --retry 2 -H 'Accept: application/json' "$url" || {
    echo "取 registry 元数据失败: $url" >&2; return 1; }
}

# JSON -> TSV。stdin=JSON，$1=pkg $2=selector $3=kind。
# 严格校验字段存在性与类型：缺 integrity 一律失败，**绝不退化成只看版本**。
inputs_meta_extract() {
  command -v python3 >/dev/null 2>&1 || { echo "解析 registry 元数据需要 python3" >&2; return 1; }
  python3 -c '
import json, sys

pkg, selector, kind = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    meta = json.load(sys.stdin)
except Exception as exc:
    print("registry 返回的不是合法 JSON: %s" % exc, file=sys.stderr); sys.exit(1)

if kind == "dist-tag":
    tags = meta.get("dist-tags")
    if not isinstance(tags, dict):
        print("元数据缺少 dist-tags", file=sys.stderr); sys.exit(1)
    version = tags.get(selector)
    if not isinstance(version, str) or not version:
        print("dist-tag %r 不存在（现有: %s）" % (selector, ", ".join(sorted(tags))), file=sys.stderr)
        sys.exit(1)
    dist_tag = selector
    versions = meta.get("versions")
    if not isinstance(versions, dict) or version not in versions:
        print("dist-tag 指向的版本 %s 不在 versions 里" % version, file=sys.stderr); sys.exit(1)
    entry = versions[version]
    name = meta.get("name", pkg)
else:
    version, dist_tag = selector, ""
    entry = meta
    name = meta.get("name", pkg)

if name != pkg:
    print("元数据里的包名 %r 与请求的 %r 不一致" % (name, pkg), file=sys.stderr); sys.exit(1)
if entry.get("version") != version:
    print("元数据 version 字段 %r 与预期 %r 不一致" % (entry.get("version"), version), file=sys.stderr)
    sys.exit(1)
dist = entry.get("dist")
if not isinstance(dist, dict):
    print("元数据缺少 dist", file=sys.stderr); sys.exit(1)
integrity = dist.get("integrity")
if not isinstance(integrity, str) or not integrity:
    print("元数据缺少 dist.integrity（不接受退化为版本检查）", file=sys.stderr); sys.exit(1)
if not (integrity.startswith("sha512-") or integrity.startswith("sha1-")):
    print("不支持的 SRI 形式: %s" % integrity, file=sys.stderr); sys.exit(1)
tarball = dist.get("tarball")
if not isinstance(tarball, str) or not tarball:
    print("元数据缺少 dist.tarball", file=sys.stderr); sys.exit(1)
shasum = dist.get("shasum") or ""

for k, v in (("package", name), ("version", version), ("dist_tag", dist_tag),
             ("selector_kind", kind), ("selector", selector),
             ("integrity", integrity), ("tarball", tarball), ("shasum", shasum)):
    print("%s\t%s" % (k, v))
' "$1" "$2" "$3"
}

# 解析 + 原子冻结 + 计算摘要。$1=输出文件（run 目录内）
# 成功: 设 NPM_TARGET_FILE / NPM_TARGET_DIGEST，并导出供 case 使用的变量；返回 0
# 失败: 打印可读原因；返回 1（调用者据此把**依赖该输入的 case** 记 UNMET）
inputs_freeze_npm_target() {
  local out="$1" spec pkg kind meta
  spec="${DSH_NPM_SPEC:-$NPM_SPEC_DEFAULT}"
  inputs_parse_spec "$spec" || return 1
  pkg="$INPUTS_PKG"; kind="$INPUTS_KIND"

  if [ "$kind" = version ]; then
    meta="$(inputs_fetch_meta "$pkg" "$INPUTS_SEL")" || return 1
  else
    meta="$(inputs_fetch_meta "$pkg")" || return 1
  fi
  local parsed
  parsed="$(printf '%s' "$meta" | inputs_meta_extract "$pkg" "$INPUTS_SEL" "$kind")" || return 1

  local reg; reg="$(inputs_npm_registry)"
  case "$reg" in
    http://127.0.0.1*|http://localhost*) ;;   # 冒烟用的本地夹具 registry
    http://*) echo "拒绝明文 http registry（除非本机回环）: $reg" >&2; return 1 ;;
  esac

  local tmp="$out.tmp"
  {
    printf 'schema\tdsh-termux-input-npm-target/1\n'
    printf 'role\tdefault-target\n'
    printf 'requested_spec\t%s\n' "$spec"
    printf 'registry\t%s\n' "$reg"
    printf '%s\n' "$parsed"
  } > "$tmp" || return 1
  mv -f "$tmp" "$out" || return 1

  NPM_TARGET_FILE="$out"
  NPM_TARGET_DIGEST="$(sha256sum "$out" | cut -d' ' -f1)"
  NPM_TARGET_VERSION="$(sed -n 's/^version\t//p' "$out")"
  NPM_TARGET_INTEGRITY="$(sed -n 's/^integrity\t//p' "$out")"
  NPM_TARGET_TARBALL="$(sed -n 's/^tarball\t//p' "$out")"
  NPM_TARGET_PACKAGE="$(sed -n 's/^package\t//p' "$out")"

  # case 拿到的是**精确完整 spec**而不是 dist-tag: 交给真实安装入口时不得再解析一次。
  export DSH_NPM_TARGET_FILE="$NPM_TARGET_FILE"
  export DSH_NPM_PACKAGE="$NPM_TARGET_PACKAGE"
  export DSH_NPM_VERSION="$NPM_TARGET_VERSION"
  export DSH_NPM_SPEC="${NPM_TARGET_PACKAGE}@${NPM_TARGET_VERSION}"
  export DSH_NPM_INTEGRITY="$NPM_TARGET_INTEGRITY"
  export DSH_NPM_TARBALL="$NPM_TARGET_TARBALL"
  export DSH_NPM_REGISTRY="$reg"
  export DSH_NPM_TARGET_DIGEST="$NPM_TARGET_DIGEST"
  return 0
}

# 选中集合里是否有 case 声明了某个输入种类（只有这时才值得联网解析）。
# `npm-spec` → 解析并冻结 default-target；`release-*` → 解析并冻结发布物输入实例
# （ADR-011：发布物认证是 (case, 输入实例)，实例身份必须进报告与轮次）。
inputs_selection_needs() { # $1=输入种类名
  local i
  for i in "${!REG_ID[@]}"; do
    [ "${REG_SELECTED[$i]}" = yes ] || continue
    _csv_has "${REG_INPUTS[$i]}" "$1" && return 0
  done
  return 1
}
