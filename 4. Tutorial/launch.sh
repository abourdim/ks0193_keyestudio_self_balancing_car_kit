#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# KS0193 self-balancing car workshop launcher -- check/install a toolchain,
# unpack the bundled libraries, then build, flash, and monitor any of the 13
# lesson sketches under "Test Code/".
#
# Two backends are supported and interchangeable:
#   * PlatformIO  -- generates a throwaway project per lesson under .build/
#   * arduino-cli -- compiles the lesson folder in place, build output in .build/
# Either way "Test Code/" itself is never modified.
#
# Board: Arduino UNO (ATmega328P) -- keyestudio's balance-car shield sits on a
# plain UNO, so the FQBN/board id is the stock one.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKETCH_ROOT="$SCRIPT_DIR/Test Code"
LIB_ZIP_DIR="$SCRIPT_DIR/Libraries"
BUILD_ROOT="$SCRIPT_DIR/.build"
LIB_DIR="$BUILD_ROOT/libraries"
TOOLS_DIR="$SCRIPT_DIR/.tools"

FQBN="arduino:avr:uno"
MONITOR_BAUD=9600          # every lesson calls Serial.begin(9600)

# --- colors -----------------------------------------------------------------
if [ -t 1 ]; then
  C_RESET='\033[0m'; C_DIM='\033[2m'
  C_CYAN='\033[36m'; C_AMBER='\033[33m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_BOLD='\033[1m'
else
  C_RESET=''; C_DIM=''; C_CYAN=''; C_AMBER=''; C_RED=''; C_GREEN=''; C_BOLD=''
fi

ok()    { echo -e "${C_GREEN}[OK]${C_RESET} $1"; }
warn()  { echo -e "${C_AMBER}[!!]${C_RESET} $1"; }
err()   { echo -e "${C_RED}[XX]${C_RESET} $1"; }
info()  { echo -e "${C_CYAN}[--]${C_RESET} $1"; }

banner() {
  echo -e "${C_CYAN}${C_BOLD}"
  echo "  ┌──────────────────────────────────────────────┐"
  echo "  │  🛴  KS0193 BALANCE CAR -- WORKSHOP LAUNCH    │"
  echo "  └──────────────────────────────────────────────┘"
  echo -e "${C_RESET}"
}

pause() { read -rp "$(echo -e "${C_DIM}Press Enter to continue...${C_RESET}")" _; }

# Git Bash / MSYS hands us /d/work/... paths, which a native-Windows PlatformIO or
# arduino-cli cannot open. Shell arguments get mangled back automatically, but
# anything we *write into a config file* has to be converted by hand.
native_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi
}

# --- command echo ---------------------------------------------------------------
# The whole point of this launcher for a workshop is that nothing it does is
# magic: every real command is printed before it runs, in a form a kid can retype
# in a terminal opened on this folder. Absolute paths are shortened back to "./",
# and the toolchain binaries back to their bare names, so the printed line is the
# line you would type yourself.
SHOW_CMD=1

shorten() {
  local p="$1"
  case "$p" in
    "$SCRIPT_DIR") echo "$p"; return ;;          # a literal `cd` target stays absolute
    "$SCRIPT_DIR"/*) echo ".${p#"$SCRIPT_DIR"}"; return ;;
  esac
  [ -n "$PIO_BIN" ]  && [ "$p" = "$PIO_BIN" ]  && { echo "pio"; return; }
  [ -n "$ACLI_BIN" ] && [ "$p" = "$ACLI_BIN" ] && { echo "arduino-cli"; return; }
  echo "$p"
}

fmt_cmd() {
  local out="" a
  for a in "$@"; do
    a="$(shorten "$a")"
    case "$a" in
      ''|*[[:space:]]*) out+=" \"$a\"" ;;
      *)                out+=" $a" ;;
    esac
  done
  printf '%s' "${out# }"
}

echo_cmd() {
  [ "$SHOW_CMD" = "1" ] && echo -e "${C_DIM}\$ $(fmt_cmd "$@")${C_RESET}"
  return 0
}

# For the handful of shell constructs (pipes, heredocs) that are not a plain
# argv and so cannot go through fmt_cmd.
echo_raw() {
  [ "$SHOW_CMD" = "1" ] && echo -e "${C_DIM}\$ $1${C_RESET}"
  return 0
}

# Print, then run, preserving the command's own exit status.
run_cmd() { echo_cmd "$@"; "$@"; }

# --- lesson discovery ---------------------------------------------------------
# Any "Test Code/<name>/<name>.ino" is a selectable lesson. Sorted so the
# numeric prefixes (01_button_buzzer, 02_TB6612_motor, ...) come out in order.
APP_NAMES=()
APP_DIRS=()
APP_INOS=()

discover_apps() {
  APP_NAMES=(); APP_DIRS=(); APP_INOS=()
  while IFS= read -r ino; do
    local dir; dir="$(dirname "$ino")"
    APP_DIRS+=("$dir")
    APP_NAMES+=("$(basename "$dir")")
    APP_INOS+=("$ino")
  done < <(find "$SKETCH_ROOT" -mindepth 2 -maxdepth 2 -name '*.ino' | sort)
}

APP_DIR=""
APP_NAME=""
APP_INO=""
APP_IDX=""

select_app() {
  discover_apps
  if [ ${#APP_NAMES[@]} -eq 0 ]; then
    err "No .ino lessons found under $SKETCH_ROOT"
    APP_DIR=""; APP_NAME=""; APP_INO=""; APP_IDX=""
    return 1
  fi
  echo
  info "Available lessons:"
  local i
  for i in "${!APP_NAMES[@]}"; do
    printf "  %2d) %s\n" "$((i+1))" "${APP_NAMES[$i]}"
  done
  echo
  read -rp "Choose a lesson [1-${#APP_NAMES[@]}]: " sel || { echo; info "Bye."; exit 0; }
  if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le ${#APP_NAMES[@]} ]; then
    APP_DIR="${APP_DIRS[$((sel-1))]}"
    APP_NAME="${APP_NAMES[$((sel-1))]}"
    APP_INO="${APP_INOS[$((sel-1))]}"
    APP_IDX="${APP_NAME%%_*}"        # "09_Upright_loop" -> "09"
    ok "Selected: $APP_NAME"
  else
    warn "Unrecognized choice, keeping current selection ($APP_NAME)."
  fi
  pause
}

require_app() {
  if [ -z "$APP_DIR" ]; then
    warn "No lesson selected yet -- pick one first."
    select_app
  fi
  [ -n "$APP_DIR" ]
}

# --- kit-specific safety notes -------------------------------------------------
# Printed before every flash. The two real foot-guns on this kit are the HC-06
# sitting on the hardware UART, and the balance sketches spinning the motors the
# instant the board comes out of reset.
sketch_warnings() {
  case "$APP_IDX" in
    05|11|12|13)
      warn "This lesson talks to the HC-06 over the HARDWARE serial port (D0/D1)."
      warn "  * Unplug the Bluetooth module before uploading -- left in place it"
      warn "    fights the USB-serial chip and the upload fails at 'not in sync'."
      warn "  * Plug it back in after the upload completes."
      warn "  * The serial monitor shares that same UART, so it and the phone app"
      warn "    cannot both be connected."
      ;;
  esac
  case "$APP_IDX" in
    09|10|11|12|13)
      warn "This lesson runs the balance loop: the motors spin as soon as the board"
      warn "boots or is reset. Put the car on a stand or hold it before flashing."
      warn "Hold it still and UPRIGHT at power-on -- the MPU6050 samples its gyro"
      warn "offset during setup(), and moving it there poisons the balance point."
      ;;
    02|05)
      warn "This lesson drives the motors directly -- make sure the car has room"
      warn "to move, or lift the wheels off the table."
      ;;
  esac
  warn "Motor power comes from the battery pack, not USB: switch the pack ON, or"
  warn "the sketch will run while the wheels stay dead."
}

# --- backend discovery ---------------------------------------------------------
BACKEND=""                 # "pio" | "acli"
PIO_BIN=""
ACLI_BIN=""

find_pio() {
  if command -v pio >/dev/null 2>&1; then
    PIO_BIN="$(command -v pio)"
    return 0
  fi
  if [ -x "$HOME/.platformio/penv/bin/pio" ]; then
    PIO_BIN="$HOME/.platformio/penv/bin/pio"
    return 0
  fi
  PIO_BIN=""
  return 1
}

find_acli() {
  if command -v arduino-cli >/dev/null 2>&1; then
    ACLI_BIN="$(command -v arduino-cli)"
    return 0
  fi
  local c
  for c in "$TOOLS_DIR/bin/arduino-cli" "$TOOLS_DIR/bin/arduino-cli.exe" \
           "$TOOLS_DIR/arduino-cli" "$TOOLS_DIR/arduino-cli.exe"; do
    if [ -x "$c" ]; then ACLI_BIN="$c"; return 0; fi
  done
  ACLI_BIN=""
  return 1
}

# Pick a backend automatically the first time: whichever is installed, PlatformIO
# first if both are. The user can override from the menu.
autodetect_backend() {
  [ -n "$BACKEND" ] && return 0
  if find_pio; then BACKEND="pio"
  elif find_acli; then BACKEND="acli"
  fi
}

backend_label() {
  case "$BACKEND" in
    pio)  echo "PlatformIO" ;;
    acli) echo "arduino-cli" ;;
    *)    echo "none" ;;
  esac
}

select_backend() {
  echo
  info "Build backend:"
  if find_pio; then echo "  1) PlatformIO   (found: $PIO_BIN)"; else echo "  1) PlatformIO   (not installed)"; fi
  if find_acli; then echo "  2) arduino-cli  (found: $ACLI_BIN)"; else echo "  2) arduino-cli  (not installed)"; fi
  echo "  b) back"
  read -rp "Choose a backend: " choice
  case "$choice" in
    1) BACKEND="pio";  ok "Backend: PlatformIO" ;;
    2) BACKEND="acli"; ok "Backend: arduino-cli" ;;
    b|B) return ;;
    *) warn "Unrecognized option." ;;
  esac
  pause
}

require_backend() {
  autodetect_backend
  case "$BACKEND" in
    pio)  find_pio  && return 0; err "PlatformIO not found -- install it from the menu."; return 1 ;;
    acli) find_acli && return 0; err "arduino-cli not found -- install it from the menu."; return 1 ;;
    *)    err "No build backend available. Install PlatformIO or arduino-cli first."; return 1 ;;
  esac
}

# --- libraries -----------------------------------------------------------------
# The four bundled zips are Arduino 1.0-format libraries (no library.properties),
# so they are unpacked into .build/libraries/ and handed to the compiler as an
# extra search path rather than "installed" into a sketchbook.
libs_ready() {
  [ -d "$LIB_DIR/I2Cdev" ] && [ -d "$LIB_DIR/MPU6050" ] \
    && [ -d "$LIB_DIR/MsTimer2" ] && [ -d "$LIB_DIR/PinChangeInt" ]
}

prepare_libs() {
  echo
  if ! command -v unzip >/dev/null 2>&1; then
    err "unzip not found -- needed to unpack $LIB_ZIP_DIR/*.zip"
    pause; return 1
  fi
  info "Unpacking bundled libraries into $LIB_DIR ..."
  run_cmd mkdir -p "$LIB_DIR"
  local z
  for z in "$LIB_ZIP_DIR"/*.zip; do
    [ -e "$z" ] || { err "No zips found in $LIB_ZIP_DIR"; pause; return 1; }
    run_cmd unzip -q -o "$z" -d "$LIB_DIR" && ok "unpacked $(basename "$z")"
  done
  # PinChangeInt-master.zip expands to a folder whose name no longer matches its
  # header; both PlatformIO's LDF and arduino-cli are happier once it does.
  if [ -d "$LIB_DIR/PinChangeInt-master" ]; then
    run_cmd rm -rf "$LIB_DIR/PinChangeInt"
    run_cmd mv "$LIB_DIR/PinChangeInt-master" "$LIB_DIR/PinChangeInt"
    ok "renamed PinChangeInt-master -> PinChangeInt"
  fi
  if libs_ready; then ok "Libraries ready."; else warn "Some libraries are still missing -- check $LIB_DIR"; fi

  # arduino-cli additionally needs the AVR core; PlatformIO pulls atmelavr in on
  # its own at first build.
  if [ "$BACKEND" = "acli" ] && find_acli; then
    info "Making sure the arduino:avr core is installed..."
    run_cmd "$ACLI_BIN" core update-index \
      && run_cmd "$ACLI_BIN" core install arduino:avr \
      && ok "arduino:avr core ready."
  fi
  pause
}

require_libs() {
  if libs_ready; then return 0; fi
  warn "Bundled libraries are not unpacked yet -- doing it now."
  prepare_libs
  libs_ready
}

# --- PlatformIO backend --------------------------------------------------------
# One throwaway project per lesson. Both the project dir and the sketch file are
# deliberately given SHORT names ("13", "sketch.ino"): the full lesson name pushes
# .pio/build/uno/src/<name>.ino.cpp.o past Windows' 260-character path limit.
PIO_PROJ=""

pio_prepare_project() {
  PIO_PROJ="$BUILD_ROOT/$APP_IDX"
  run_cmd mkdir -p "$PIO_PROJ/src"
  echo_raw "cat > $(shorten "$PIO_PROJ")/platformio.ini <<'EOF'"
  cat > "$PIO_PROJ/platformio.ini" <<EOF
; Generated by launch.sh for "$APP_NAME" -- edits here are overwritten.
; Source of truth is Test Code/$APP_NAME/.
[env:uno]
platform = atmelavr
board = uno
framework = arduino
monitor_speed = $MONITOR_BAUD
; The four bundled keyestudio libraries, unpacked next door in .build/libraries/.
lib_extra_dirs = ../libraries
EOF
  # Showing the generated project file is half the lesson: it is the whole
  # "which board, which libraries, which baud rate" answer in six lines.
  if [ "$SHOW_CMD" = "1" ]; then
    sed 's/^/    /' "$PIO_PROJ/platformio.ini"
    echo -e "${C_DIM}    EOF${C_RESET}"
  fi
  run_cmd rm -f "$PIO_PROJ/src/sketch.ino"
  run_cmd cp "$APP_INO" "$PIO_PROJ/src/sketch.ino"
}

pio_run() { run_cmd "$PIO_BIN" "$@"; }

# --- arduino-cli backend -------------------------------------------------------
# Compiles the lesson folder where it lives (read-only), with the build output
# redirected under .build/acli/<NN>/ so nothing lands in "Test Code/".
ACLI_BUILD=""
ACLI_BUILD_N=""
ACLI_LIB_N=""
ACLI_SKETCH_N=""

acli_prepare() {
  ACLI_BUILD="$BUILD_ROOT/acli/$APP_IDX"
  mkdir -p "$ACLI_BUILD"
  ACLI_BUILD_N="$(native_path "$ACLI_BUILD")"
  ACLI_LIB_N="$(native_path "$LIB_DIR")"
  ACLI_SKETCH_N="$(native_path "$APP_DIR")"
}

# --- menu actions ---------------------------------------------------------------

check_install() {
  echo
  info "Checking for prerequisites..."

  if command -v python3 >/dev/null 2>&1; then
    ok "python3 found: $(python3 --version 2>&1)"
  else
    warn "python3 not found -- required to install/run PlatformIO (not needed for arduino-cli)."
  fi

  if command -v unzip >/dev/null 2>&1; then ok "unzip found"; else err "unzip not found -- needed to unpack the bundled libraries."; fi

  if find_pio; then
    ok "PlatformIO found at: $PIO_BIN"
    run_cmd "$PIO_BIN" --version
  else
    warn "PlatformIO not found."
  fi

  if find_acli; then
    ok "arduino-cli found at: $ACLI_BIN"
    run_cmd "$ACLI_BIN" version
  else
    warn "arduino-cli not found."
  fi

  echo
  if libs_ready; then ok "Bundled libraries unpacked in $LIB_DIR"; else warn "Bundled libraries not unpacked yet (menu option 3)."; fi

  echo
  discover_apps
  if [ ${#APP_NAMES[@]} -gt 0 ]; then
    ok "Found ${#APP_NAMES[@]} lesson(s) under $SKETCH_ROOT:"
    local n; for n in "${APP_NAMES[@]}"; do echo "     - $n"; done
  else
    err "No .ino lessons found under $SKETCH_ROOT"
  fi
  pause
}

install_tools() {
  echo
  info "Install a build backend:"
  echo "  1) PlatformIO via pip (fast, needs python3 + pip3)"
  echo "  2) PlatformIO via the official installer script (self-contained virtualenv)"
  echo "  3) arduino-cli into $TOOLS_DIR (official installer script)"
  echo "  b) back"
  read -rp "Choose an option: " choice
  case "$choice" in
    1)
      if ! command -v pip3 >/dev/null 2>&1; then
        err "pip3 not found. Install Python 3 + pip first, or use option 2."
      else
        run_cmd pip3 install -U platformio && ok "Installed. You may need to restart your shell or add pip's bin dir to PATH."
      fi
      ;;
    2)
      if ! command -v python3 >/dev/null 2>&1; then
        err "python3 not found. Install Python 3 first."
      else
        run_cmd curl -fsSL -o /tmp/get-platformio.py \
          https://raw.githubusercontent.com/platformio/platformio-core-installer/master/get-platformio.py \
          && run_cmd python3 /tmp/get-platformio.py \
          && ok "Installed to ~/.platformio. Add ~/.platformio/penv/bin to your PATH."
      fi
      ;;
    3)
      run_cmd mkdir -p "$TOOLS_DIR"
      info "Downloading arduino-cli into $TOOLS_DIR/bin ..."
      echo_raw "curl -fsSL https://raw.githubusercontent.com/arduino/arduino-cli/master/install.sh | BINDIR=$(shorten "$TOOLS_DIR")/bin sh"
      if curl -fsSL https://raw.githubusercontent.com/arduino/arduino-cli/master/install.sh \
           | BINDIR="$TOOLS_DIR/bin" sh; then
        find_acli && ok "arduino-cli installed at $ACLI_BIN"
      else
        err "Install script failed."
        info "On Windows, grab the zip manually from"
        info "  https://github.com/arduino/arduino-cli/releases"
        info "and drop arduino-cli.exe into $TOOLS_DIR/bin/"
      fi
      ;;
    b|B) return ;;
    *) warn "Unrecognized option." ;;
  esac
  pause
}

build_firmware() {
  require_app || return
  require_backend || { pause; return; }
  require_libs || { pause; return; }
  echo
  info "Building $APP_NAME with $(backend_label)..."
  case "$BACKEND" in
    pio)
      pio_prepare_project
      pio_run run -d "$PIO_PROJ" && ok "Build succeeded." || err "Build failed -- see output above."
      ;;
    acli)
      acli_prepare
      run_cmd "$ACLI_BIN" compile --fqbn "$FQBN" --libraries "$ACLI_LIB_N" \
        --build-path "$ACLI_BUILD_N" "$ACLI_SKETCH_N" \
        && ok "Build succeeded." || err "Build failed -- see output above."
      ;;
  esac
  pause
}

clean_firmware() {
  require_app || return
  echo
  info "Cleaning build artifacts for $APP_NAME..."
  run_cmd rm -rf "$BUILD_ROOT/$APP_IDX" "$BUILD_ROOT/acli/$APP_IDX"
  ok "Cleaned."
  pause
}

list_ports() {
  echo
  info "Detected serial devices:"
  if find_pio; then pio_run device list
  elif find_acli; then run_cmd "$ACLI_BIN" board list
  else err "Need PlatformIO or arduino-cli to list ports."
  fi
  pause
}

SELECTED_PORT=""

pick_port() {
  # Prints nothing on failure/no-selection; sets $SELECTED_PORT
  SELECTED_PORT=""
  echo
  info "Available serial ports:"
  if [ "$BACKEND" = "acli" ] && find_acli; then run_cmd "$ACLI_BIN" board list
  elif find_pio; then pio_run device list
  fi
  echo
  read -rp "Enter the port to use (e.g. /dev/ttyUSB0 or COM5), or leave blank for auto-detect: " SELECTED_PORT
}

flash_firmware() {
  require_app || return
  require_backend || { pause; return; }
  require_libs || { pause; return; }
  echo
  sketch_warnings
  echo
  pick_port
  echo
  info "Flashing $APP_NAME with $(backend_label)..."
  case "$BACKEND" in
    pio)
      pio_prepare_project
      if [ -n "$SELECTED_PORT" ]; then
        pio_run run -t upload --upload-port "$SELECTED_PORT" -d "$PIO_PROJ" && ok "Flash succeeded." || err "Flash failed -- see output above."
      else
        pio_run run -t upload -d "$PIO_PROJ" && ok "Flash succeeded." || err "Flash failed -- see output above."
      fi
      ;;
    acli)
      acli_prepare
      if [ -n "$SELECTED_PORT" ]; then
        run_cmd "$ACLI_BIN" compile --fqbn "$FQBN" --libraries "$ACLI_LIB_N" \
          --build-path "$ACLI_BUILD_N" -u -p "$SELECTED_PORT" "$ACLI_SKETCH_N" \
          && ok "Flash succeeded." || err "Flash failed -- see output above."
      else
        err "arduino-cli needs an explicit port -- rerun and enter one (option 8 lists them)."
      fi
      ;;
  esac
  pause
}

monitor_serial() {
  require_backend || { pause; return; }
  echo
  pick_port
  echo
  info "Opening serial monitor at $MONITOR_BAUD baud. Press Ctrl+C to exit."
  warn "If the HC-06 is plugged into D0/D1, unplug it first -- it and the monitor"
  warn "share the one hardware UART."
  case "$BACKEND" in
    pio)
      if [ -n "$SELECTED_PORT" ]; then pio_run device monitor -b "$MONITOR_BAUD" -p "$SELECTED_PORT"
      else pio_run device monitor -b "$MONITOR_BAUD"; fi
      ;;
    acli)
      if [ -n "$SELECTED_PORT" ]; then run_cmd "$ACLI_BIN" monitor -p "$SELECTED_PORT" -c "baudrate=$MONITOR_BAUD"
      else err "arduino-cli needs an explicit port."; pause; fi
      ;;
  esac
}

build_flash_monitor() {
  require_app || return
  build_firmware
  flash_firmware
  read -rp "Open serial monitor now? [y/N] " yn
  case "$yn" in
    y|Y) monitor_serial ;;
    *) ;;
  esac
}

# --- the replay sheet -----------------------------------------------------------
# Everything the launcher would do for the selected lesson, as plain commands and
# nothing else. Built from the same variables the real actions use, so it cannot
# drift away from what actually runs.
RECIPE=()
rl() { RECIPE+=("$1"); }                       # raw line (comment / blank)
rc() { RECIPE+=("  $(fmt_cmd "$@")"); }        # command line, indented

build_recipe() {
  local port="${SELECTED_PORT:-COM5}"
  RECIPE=()
  rl "# ==================================================================="
  rl "# $APP_NAME"
  rl "# Toolchain: $(backend_label)   Board: $FQBN   Serial: $MONITOR_BAUD baud"
  rl "# ==================================================================="
  rl ""
  rl "# Open a terminal on the tutorial folder:"
  rc cd "$SCRIPT_DIR"
  rl ""
  rl "# --- once per computer: unpack the four bundled libraries ----------"
  rc mkdir -p "$LIB_DIR"
  local z
  for z in "$LIB_ZIP_DIR"/*.zip; do
    [ -e "$z" ] || continue
    rc unzip -o "$z" -d "$LIB_DIR"
  done
  rl "# the zip unpacks under its GitHub name; the folder must match the header"
  rc mv "$LIB_DIR/PinChangeInt-master" "$LIB_DIR/PinChangeInt"
  rl ""

  case "$BACKEND" in
    pio)
      rl "# --- build a tiny PlatformIO project for this lesson ---------------"
      rl "# (short names on purpose: the full lesson name overruns Windows' 260"
      rl "#  character path limit once .pio/build/... is appended)"
      rc mkdir -p "$BUILD_ROOT/$APP_IDX/src"
      rc cp "$APP_INO" "$BUILD_ROOT/$APP_IDX/src/sketch.ino"
      rl ""
      rl "# ...and write $(shorten "$BUILD_ROOT/$APP_IDX")/platformio.ini containing:"
      rl "#     [env:uno]"
      rl "#     platform = atmelavr"
      rl "#     board = uno"
      rl "#     framework = arduino"
      rl "#     monitor_speed = $MONITOR_BAUD"
      rl "#     lib_extra_dirs = ../libraries"
      rl ""
      rl "# --- compile -------------------------------------------------------"
      rc pio run -d "$BUILD_ROOT/$APP_IDX"
      rl ""
      rl "# --- find the board, then upload -----------------------------------"
      rc pio device list
      rl "# replace $port below with the port you just saw"
      rc pio run -t upload --upload-port "$port" -d "$BUILD_ROOT/$APP_IDX"
      rl ""
      rl "# --- watch what the sketch prints (Ctrl+C to quit) -----------------"
      rc pio device monitor -b "$MONITOR_BAUD" -p "$port"
      ;;
    acli)
      rl "# --- once per computer: install the AVR core -----------------------"
      rc arduino-cli core update-index
      rc arduino-cli core install arduino:avr
      rl ""
      rl "# --- compile (the lesson folder is read, never modified) -----------"
      rc arduino-cli compile --fqbn "$FQBN" --libraries "$LIB_DIR" \
         --build-path "$BUILD_ROOT/acli/$APP_IDX" "$APP_DIR"
      rl ""
      rl "# --- find the board, then compile + upload in one go ---------------"
      rc arduino-cli board list
      rl "# replace $port below with the port you just saw"
      rc arduino-cli compile --fqbn "$FQBN" --libraries "$LIB_DIR" \
         --build-path "$BUILD_ROOT/acli/$APP_IDX" -u -p "$port" "$APP_DIR"
      rl ""
      rl "# --- watch what the sketch prints (Ctrl+C to quit) -----------------"
      rc arduino-cli monitor -p "$port" -c "baudrate=$MONITOR_BAUD"
      ;;
    *)
      rl "# No toolchain installed yet -- use menu option 2 first."
      ;;
  esac
}

show_recipe() {
  require_app || return
  autodetect_backend
  build_recipe
  echo
  info "Every command for this lesson. Nothing below is executed -- it is yours to retype."
  echo
  printf '%s\n' "${RECIPE[@]}"
  echo
  read -rp "Save this to a file you can keep? [y/N] " yn
  case "$yn" in
    y|Y)
      local out="$BUILD_ROOT/replay_${APP_NAME}.txt"
      mkdir -p "$BUILD_ROOT"
      printf '%s\n' "${RECIPE[@]}" > "$out" && ok "Written to $out"
      ;;
  esac
  pause
}

toggle_echo() {
  if [ "$SHOW_CMD" = "1" ]; then SHOW_CMD=0; info "Command echo OFF."
  else SHOW_CMD=1; info "Command echo ON -- every command is printed before it runs."; fi
  sleep 1
}

main_menu() {
  while true; do
    clear 2>/dev/null || true
    banner
    if [ -n "$APP_NAME" ]; then
      echo -e "  Lesson:  ${C_AMBER}$APP_NAME${C_RESET}"
    else
      echo -e "  Lesson:  ${C_RED}none selected${C_RESET}"
    fi
    autodetect_backend
    if require_backend >/dev/null 2>&1; then
      echo -e "  Backend: ${C_GREEN}$(backend_label)${C_RESET}   Board: $FQBN @ ${MONITOR_BAUD} baud"
    else
      echo -e "  Backend: ${C_RED}none available${C_RESET}   Board: $FQBN @ ${MONITOR_BAUD} baud"
    fi
    if libs_ready; then
      echo -e "  Libs:    ${C_GREEN}unpacked${C_RESET}"
    else
      echo -e "  Libs:    ${C_RED}not unpacked${C_RESET} (option 3)"
    fi
    if [ "$SHOW_CMD" = "1" ]; then
      echo -e "  Echo:    ${C_GREEN}on${C_RESET}  -- every command is printed before it runs"
    else
      echo -e "  Echo:    ${C_DIM}off${C_RESET}"
    fi
    echo
    echo "  0) Select lesson"
    echo "  1) Check installation"
    echo "  2) Install PlatformIO / arduino-cli"
    echo "  3) Prepare bundled libraries"
    echo "  4) Build firmware"
    echo "  5) Flash firmware"
    echo "  6) Build + Flash + Monitor"
    echo "  7) Serial monitor"
    echo "  8) List serial ports"
    echo "  9) Clean build"
    echo "  r) Show all the commands for this lesson (nothing runs)"
    echo "  c) Toggle command echo"
    echo "  t) Switch build backend"
    echo "  q) Quit"
    echo
    read -rp "Choose an option: " opt || { echo; info "Bye."; exit 0; }
    case "$opt" in
      0) select_app ;;
      1) check_install ;;
      2) install_tools ;;
      3) prepare_libs ;;
      4) build_firmware ;;
      5) flash_firmware ;;
      6) build_flash_monitor ;;
      7) monitor_serial ;;
      8) list_ports ;;
      9) clean_firmware ;;
      r|R) show_recipe ;;
      c|C) toggle_echo ;;
      t|T) select_backend ;;
      q|Q) echo; info "Bye."; exit 0 ;;
      *) warn "Unrecognized option." ; sleep 1 ;;
    esac
  done
}

# Prompt for a lesson up front so options 4-9 have something to act on immediately.
autodetect_backend
select_app
main_menu
