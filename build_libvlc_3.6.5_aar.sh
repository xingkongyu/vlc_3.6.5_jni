#!/usr/bin/env bash
# =============================================================================
# VLC 3.6.5 Android AAR 一键构建脚本（rk3518_box_32 / armeabi-v7a）
#
# 用法：
#   ./build_libvlc_3.6.5_aar.sh              # 全流程：native + AAR
#   ./build_libvlc_3.6.5_aar.sh native       # 只编 libvlc.so / libvlcjni.so
#   ./build_libvlc_3.6.5_aar.sh aar          # 只打包 AAR（要求 native 已编好）
#   ./build_libvlc_3.6.5_aar.sh init         # 只做初始化（软链/环境/gradle wrapper）
#   ./build_libvlc_3.6.5_aar.sh check        # 只做环境自检
#
# 可选参数：
#   -a arm|arm64     目标 ABI（默认 arm = armeabi-v7a）
#   -j N             并行度（默认 nproc）
#   --clean          编 native 前先清理构建目录
#
# 日志：out/logs/build_<时间戳>.log（同时打印到终端）
# 产物：out/libvlc.<abi>.so / out/libvlcjni.<abi>.so / out/libvlc-*.aar
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# CORE_DIR 必须是【真实】的 core 源码树路径，不能是 libvlcjni/vlc 软链本身，
# 否则 init 阶段会把它指向自己、把原本正确的软链破坏掉。
CORE_DIR="${CORE_DIR:-/home/work/data1/vlc_core-3.6.5}"
VLC_LINK="$HERE/libvlcjni/vlc"

SDK="${ANDROID_SDK:-/home/work/data3/Android/Sdk}"
NDK="${ANDROID_NDK:-$SDK/ndk/21.4.7075529}"
JH="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}"
export ANDROID_SDK="$SDK" ANDROID_HOME="$SDK" ANDROID_NDK="$NDK" JAVA_HOME="$JH"
export PATH="$JH/bin:$SDK/platform-tools:$PATH"
# 保证中文输出不乱码（某些 SSH 会话 LANG 是 POSIX）
export LANG="${LANG_OVERRIDE:-C.UTF-8}" LC_ALL="${LANG_OVERRIDE:-C.UTF-8}"

# 宿主编译器固定用 gcc-13：机器上另外装过 gcc-7 且可能在 alternatives 里抢占默认，
# 用旧 gcc 编 extras/tools / contrib 容易踩新特性缺失（目标代码仍由 NDK clang 生成）
if command -v gcc-13 >/dev/null 2>&1 && command -v g++-13 >/dev/null 2>&1; then
    export CC="${CC:-gcc-13}" CXX="${CXX:-g++-13}"
fi

OUT_DIR="$HERE/out"
LOG_DIR="$OUT_DIR/logs"
mkdir -p "$LOG_DIR"
LOGFILE="$LOG_DIR/build_$(date +%Y%m%d_%H%M%S).log"
: > "$LOGFILE"

STAGE="all"
ARCH="arm"
JOBS="$(nproc)"
DO_CLEAN=0

while [ $# -gt 0 ]; do
    case "$1" in
        init|native|aar|all|check) STAGE="$1" ;;
        -a) ARCH="$2"; shift ;;
        -j) JOBS="$2"; shift ;;
        --clean) DO_CLEAN=1 ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "未知参数: $1（-h 查看用法）"; exit 2 ;;
    esac
    shift
done

case "$ARCH" in
    arm)   ABI="armeabi-v7a"; GRADLE_ABI="ARMv7" ;;
    arm64) ABI="arm64-v8a";   GRADLE_ABI="ARMv8" ;;
    *) echo "-a 只能是 arm 或 arm64"; exit 2 ;;
esac

export MAKEFLAGS="-j$JOBS"

# ---------- 输出辅助 ----------
log()  { printf '\033[36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOGFILE"; }
ok()   { printf '\033[32m[ OK ]\033[0m %s\n' "$*" | tee -a "$LOGFILE"; }
warn() { printf '\033[33m[WARN]\033[0m %s\n' "$*" | tee -a "$LOGFILE"; }
step() { printf '\n\033[1;34m========== %s ==========\033[0m\n' "$*" | tee -a "$LOGFILE"; }
die()  { printf '\033[31m[FAIL]\033[0m %s\n' "$*" | tee -a "$LOGFILE"; \
         printf '\033[31m完整日志: %s\033[0m\n' "$LOGFILE" >&2; exit 1; }

run() {   # run <描述> <命令...>
    local desc="$1"; shift
    log "▶ $desc"
    "$@" 2>&1 | tee -a "$LOGFILE"
    local rc=${PIPESTATUS[0]}
    [ "$rc" -eq 0 ] || die "$desc 失败（exit=$rc）"
}

trap 'printf "\n\033[31m[中断]\033[0m 已中止，日志: %s\n" "$LOGFILE"' INT TERM

# ---------- 1. 环境自检 ----------
check_env() {
    step "环境自检"
    local bad=0
    for c in gcc g++ make autoconf automake libtoolize pkg-config cmake yasm nasm meson ninja autopoint python3 git unzip; do
        if command -v "$c" >/dev/null 2>&1; then
            printf '  %-12s %s\n' "$c" "$(command -v "$c")" | tee -a "$LOGFILE"
        else
            printf '  \033[31m%-12s MISSING\033[0m\n' "$c" | tee -a "$LOGFILE"; bad=1
        fi
    done
    [ -x "$JH/bin/java" ] || { warn "JAVA_HOME 无效: $JH"; bad=1; }
    [ -d "$SDK" ]        || { warn "SDK 不存在: $SDK"; bad=1; }
    [ -d "$NDK" ]        || { warn "NDK 不存在: $NDK"; bad=1; }
    [ -d "$SDK/build-tools/36.0.0" ] || warn "缺少 build-tools 36.0.0（可改 settings.gradle 用 36.1.0）"

    if [ -f "$CORE_DIR/src/libvlc.h" ]; then
        ok "core 源码树: $CORE_DIR"
    else
        warn "core 源码树无效（缺 src/libvlc.h）: $CORE_DIR"; bad=1
    fi

    if [ -f "$VLC_LINK/include/vlc_subpicture.h" ] \
       && [ "$(readlink -f "$VLC_LINK")" = "$(readlink -f "$CORE_DIR")" ]; then
        ok "libvlcjni/vlc -> $CORE_DIR"
    else
        warn "libvlcjni/vlc 软链缺失或指向错误（init 阶段会修复）"
    fi

    local contrib_pkg="$CORE_DIR/contrib/contrib-android-arm-linux-androideabi/vlc-contrib-arm-linux-androideabi-latest.tar.zst"
    if [ -f "$contrib_pkg" ]; then
        ok "contrib 预编译包: $(du -h "$contrib_pkg" | cut -f1) $contrib_pkg"
    else
        warn "缺少 contrib 预编译包（-t 模式依赖它）: $contrib_pkg"
    fi

    log "java: $("$JH/bin/java" -version 2>&1 | head -1)"
    log "cc  : ${CC:-gcc} -> $(${CC:-gcc} --version | head -1)"
    log "default gcc: $(command -v gcc) ($(gcc --version | head -1))"
    log "jobs: $JOBS   abi: $ABI   ndk: $NDK"
    [ "$bad" -eq 0 ] || die "环境自检未通过，请先补齐上面的依赖项"
    ok "环境自检通过"
}

# ---------- 2. 初始化 ----------
do_init() {
    step "初始化"
    [ -f "$CORE_DIR/src/libvlc.h" ] || die "core 源码树无效: $CORE_DIR"
    run "挂接 core 源码树" ln -sfn "$CORE_DIR" "$VLC_LINK"

    # gradle wrapper 的发行包地址改国内镜像（gradle.org 在构建机只有 ~25KB/s）
    local wp="$HERE/gradle/wrapper/gradle-wrapper.properties"
    if [ -f "$wp" ] && grep -q 'services.gradle.org' "$wp"; then
        sed -i 's|^distributionUrl=.*|distributionUrl=https\\://mirrors.cloud.tencent.com/gradle/gradle-8.13-bin.zip|' "$wp"
        log "gradle 发行包已切换到腾讯镜像"
    fi

    if [ ! -x "$HERE/gradlew" ]; then
        if [ ! -x "$HERE/gradle-8.13/bin/gradle" ]; then
            die "缺少 gradle-8.13 目录，请把 gradle-8.13-bin.zip 解压到 $HERE 后重试"
        fi
        # 某些模块的 build.gradle 在配置阶段调用 git，tar 解压的树需要有 .git
        if [ ! -d "$HERE/.git" ]; then
            log "创建 git 仓库（供版本号获取）"
            ( cd "$HERE" && git init -q && git config user.email restore@local \
              && git config user.name restore && git config core.autocrlf false \
              && printf 'libvlcjni/\ngradle-8.13/\ngradle-8.13-bin.zip\n.gradle/\nbuild/\nout/\n' > .git/info/exclude \
              && git add -A >/dev/null 2>&1 && git commit -qm "scaffold" >/dev/null 2>&1 ) || true
        fi
        run "生成 gradlew" env LANG=C "$HERE/gradle-8.13/bin/gradle" -p "$HERE" wrapper --no-daemon
    fi

    run "写入 local.properties" bash -c "printf 'sdk.dir=%s\nandroid.ndkPath=%s\n' '$SDK' '$NDK' > '$HERE/local.properties'"
    ok "初始化完成"
}

# ---------- 3. 编 native ----------
do_native() {
    step "编译 libvlc（$ABI）"
    [ -f "$CORE_DIR/src/libvlc.h" ] || die "core 源码树无效: $CORE_DIR"
    [ -f "$CORE_DIR/contrib/contrib-android-arm-linux-androideabi/vlc-contrib-arm-linux-androideabi-latest.tar.zst" ] \
        || warn "未找到本地 contrib 包，将尝试联网下载（很慢）"

    if [ "$DO_CLEAN" -eq 1 ]; then
        warn "清理构建目录（保留 contrib）"
        rm -rf "$CORE_DIR"/build-android-* 2>/dev/null || true
        rm -rf "$HERE/libvlcjni/libvlc/jni/obj" 2>/dev/null || true
    fi

    # compile.sh 不会把 release 标志传给 compile-libvlc.sh（AVLC_RELEASE 为空），
    # 因此只要 build 目录里的 config.h 存在就会跳过 configure，改了 configure
    # 参数也不会生效。这里用「脚本比 config.h 新」来判定参数已变更，强制重跑。
    local build_dir="$CORE_DIR/build-android-arm-linux-androideabi"
    local helper="$HERE/libvlcjni/buildsystem/compile-libvlc.sh"
    if [ -f "$build_dir/config.h" ] && [ "$helper" -nt "$build_dir/config.h" ]; then
        warn "compile-libvlc.sh 比 config.h 新（configure 参数已变更），强制重新 configure"
        rm -f "$build_dir/config.h"
    fi

    local t0=$(date +%s)
    run "compile.sh -a $ARCH -l -t -b release" \
        "$HERE/buildsystem/compile.sh" -a "$ARCH" -l -t -b release
    local t1=$(date +%s)
    ok "libvlc 编译完成，用时 $(( (t1 - t0) / 60 )) 分 $(( (t1 - t0) % 60 )) 秒"

    local libdir="$HERE/libvlcjni/libvlc/jni/libs/$ABI"
    if [ -d "$libdir" ]; then
        mkdir -p "$OUT_DIR"
        cp -f "$libdir"/*.so "$OUT_DIR"/ 2>/dev/null || true
        log "产物:"
        ls -lh "$OUT_DIR"/*.so | tee -a "$LOGFILE"
    else
        die "未找到 native 产物目录: $libdir"
    fi
}

# ---------- 4. 打包 AAR ----------
do_aar() {
    step "打包 AAR（$ABI）"
    [ -x "$HERE/gradlew" ] || do_init

    local libdir="$HERE/libvlcjni/libvlc/jni/libs/$ABI"
    [ -d "$libdir" ] && ls "$libdir"/*.so >/dev/null 2>&1 \
        || die "native 产物缺失（$libdir），请先执行 native 阶段"

    run "gradlew -p libvlcjni publishToMavenLocal" \
        env GRADLE_ABI="$GRADLE_ABI" "$HERE/gradlew" -p "$HERE/libvlcjni" publishToMavenLocal

    local m2="$HOME/.m2/repository/org/videolan/android"
    local aar
    aar=$(find "$m2" -name 'libvlc-*.aar' -newermt '-2 hours' 2>/dev/null | head -1)
    if [ -z "$aar" ]; then
        aar=$(find "$m2" -name 'libvlc-*.aar' 2>/dev/null | sort | tail -1)
    fi
    [ -n "$aar" ] || die "在 $m2 下没找到 AAR"

    mkdir -p "$OUT_DIR"
    local dst="$OUT_DIR/libvlc-release-$(date +%Y%m%d_%H%M%S).aar"
    cp -f "$aar" "$dst"
    ok "AAR: $dst ($(du -h "$dst" | cut -f1))"
    log "源文件: $aar"
}

# ---------- 主流程 ----------
step "VLC 3.6.5 AAR 构建 - 阶段: $STAGE"
log "工作目录: $HERE"
log "日志文件: $LOGFILE"

case "$STAGE" in
    check)
        check_env
        ;;
    init)
        check_env
        do_init
        ;;
    native)
        check_env
        [ -x "$HERE/gradlew" ] || do_init
        do_native
        ;;
    aar)
        check_env
        do_aar
        ;;
    all)
        check_env
        do_init
        do_native
        do_aar
        step "全部完成"
        ok "产物目录: $OUT_DIR"
        ls -lh "$OUT_DIR" | tee -a "$LOGFILE"
        ;;
esac

printf '\n\033[32m日志: %s\033[0m\n' "$LOGFILE"
